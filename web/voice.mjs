/**
 * A small browser speech controller. Audio is handled by the browser's speech
 * provider; this module does not record or upload audio itself.
 */
import { joinSpeechSegments } from './speech-text.mjs';

export class VoiceController {
  #callbacks;
  #state = 'idle';
  #session = null;
  #destroyed = false;

  constructor({ onState, onInterim, onFinal, onTick } = {}) {
    this.#callbacks = { onState, onInterim, onFinal, onTick };
  }

  get supported() {
    return typeof this.#recognitionConstructor() === 'function';
  }

  get state() {
    return this.#state;
  }

  start(lang = 'zh-CN') {
    if (this.#destroyed || this.#session) return false;

    const Recognition = this.#recognitionConstructor();
    if (typeof Recognition !== 'function') {
      this.#setState('error', '当前浏览器暂不支持语音转文字，请尝试支持语音识别的 Chrome 等浏览器，或直接输入文字。');
      return false;
    }

    let recognition;
    try {
      recognition = new Recognition();
      recognition.lang = ['zh-CN', 'zh-TW', 'zh-HK', 'en-US'].includes(lang) ? lang : 'zh-CN';
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.maxAlternatives = 1;
    } catch {
      this.#setState('error', '语音服务暂时无法启动，请稍后重试。');
      return false;
    }

    const session = {
      recognition,
      entries: [],
      delivered: new Set(),
      timer: null,
      stopTimer: null,
      startedAt: null,
      lastSeconds: 0,
      stopRequested: false,
      failure: '',
      hasText: false,
    };
    this.#session = session;
    this.#emit('onInterim', '');
    this.#emit('onTick', 0);
    this.#setState('starting', '正在连接语音服务；首次使用时，请允许麦克风权限。');

    recognition.onstart = () => {
      if (!this.#isCurrent(session)) return;
      if (session.stopRequested) {
        // stop() can be pressed while the browser is still starting.
        this.#requestStop(session);
        return;
      }
      session.startedAt = Date.now();
      session.timer = setInterval(() => this.#tick(session), 250);
      this.#setState('listening', '正在聆听，清楚说话即可；完成后点击停止。');
    };

    recognition.onresult = (event) => {
      if (!this.#isCurrent(session) || session.failure) return;
      // Results include the full session. Mutable interim entries can be
      // replaced or removed, so rebuild that snapshot instead of appending it.
      session.entries = Array.from(event.results, (result) => ({
        text: String(result[0]?.transcript ?? ''),
        final: Boolean(result.isFinal),
      }));
      this.#deliverFinals(session);
      if (!this.#isCurrent(session)) return;
      this.#emit('onInterim', this.#pendingText(session));
    };

    recognition.onerror = (event) => {
      if (!this.#isCurrent(session)) return;
      // Some providers emit "aborted" after an intentional stop.
      if (event.error === 'aborted' && session.stopRequested) return;
      session.failure = this.#errorMessage(event.error);
      this.#clearTimers(session);
      this.#setState('error', session.failure);
    };

    recognition.onend = () => {
      if (!this.#isCurrent(session)) return;
      this.#finish(session);
    };

    try {
      recognition.start();
      return true;
    } catch (error) {
      session.failure = error?.name === 'NotAllowedError'
        ? this.#errorMessage('not-allowed')
        : '语音服务未能启动，请检查麦克风权限后重试。';
      this.#release(session);
      this.#setState('error', session.failure);
      return false;
    }
  }

  stop() {
    const session = this.#session;
    if (!session || session.stopRequested) return false;
    session.stopRequested = true;
    this.#tick(session);
    this.#setState('stopping', '正在整理最后一句，请稍等…');
    if (!this.#isCurrent(session)) return true;
    this.#requestStop(session);
    if (!this.#isCurrent(session)) return true;

    // A provider may fail to send onend. Give normal stop() time to flush its
    // final result, then recover without leaving the controls stuck forever.
    session.stopTimer = setTimeout(() => {
      if (!this.#isCurrent(session)) return;
      try { session.recognition.abort(); } catch { /* Already ended. */ }
      if (this.#isCurrent(session)) this.#finish(session);
    }, 4000);
    return true;
  }

  cancel() {
    if (this.#destroyed) return false;
    const session = this.#session;
    if (session) {
      // Invalidate the session before abort(): even already-queued callbacks
      // must not deliver a last result after local data has been deleted.
      this.#release(session);
      session.entries = [];
      session.delivered.clear();
      try { session.recognition.abort(); } catch { /* Already ended. */ }
    }
    this.#emit('onInterim', '');
    this.#emit('onTick', 0);
    this.#setState('idle', '听写已取消。');
    return Boolean(session);
  }

  destroy() {
    this.#destroyed = true;
    const session = this.#session;
    if (session) {
      this.#release(session);
      try { session.recognition.abort(); } catch { /* Already ended. */ }
    }
    this.#state = 'idle';
    this.#callbacks = {};
  }

  #recognitionConstructor() {
    return globalThis.SpeechRecognition || globalThis.webkitSpeechRecognition;
  }

  #isCurrent(session) {
    return !this.#destroyed && this.#session === session;
  }

  #setState(state, message) {
    this.#state = state;
    this.#emit('onState', state, message);
  }

  #emit(name, ...args) {
    const callback = this.#callbacks[name];
    if (typeof callback === 'function') callback(...args);
  }

  #tick(session) {
    if (!this.#isCurrent(session) || session.startedAt === null) return;
    const seconds = Math.floor((Date.now() - session.startedAt) / 1000);
    if (seconds !== session.lastSeconds) {
      session.lastSeconds = seconds;
      this.#emit('onTick', seconds);
    }
  }

  #deliverFinals(session) {
    const newlyFinal = [];
    session.entries.forEach((entry, index) => {
      if (!entry.final || session.delivered.has(index)) return;
      session.delivered.add(index);
      if (entry.text.trim()) newlyFinal.push(entry.text);
    });
    if (newlyFinal.length) {
      session.hasText = true;
      this.#emit('onFinal', newlyFinal.reduce(joinSpeechSegments, ''));
    }
  }

  #pendingText(session) {
    const pending = session.entries
      .filter((entry, index) => !entry.final && !session.delivered.has(index))
      .map((entry) => entry.text)
      .reduce(joinSpeechSegments, '');
    return pending.trim() ? pending : '';
  }

  #requestStop(session) {
    try {
      // stop() lets the browser send a last result; abort() would discard it.
      session.recognition.stop();
    } catch {
      // An early stop during permission/startup is retried by onstart.
    }
  }

  #finish(session) {
    this.#tick(session);
    if (!this.#isCurrent(session)) return;
    this.#deliverFinals(session);
    if (!this.#isCurrent(session)) return;
    const pending = this.#pendingText(session);
    const keptTail = session.stopRequested && !session.failure && Boolean(pending);
    if (keptTail) {
      // Preserve the latest draft if a provider ends without finalizing its
      // interim text. This happens only after end, preventing duplicate tails.
      session.hasText = true;
      this.#emit('onFinal', pending);
      if (!this.#isCurrent(session)) return;
    }
    const message = session.failure
      || (keptTail ? '已停止，末尾文字已保留，请校对识别结果。'
        : session.hasText ? '本次语音已结束，文字已保留。'
          : session.stopRequested ? '已停止，本次没有识别到文字。'
            : '语音服务已结束，点击开始可继续。');
    this.#release(session);
    this.#emit('onInterim', '');
    this.#setState('idle', message);
  }

  #clearTimers(session) {
    clearInterval(session.timer);
    clearTimeout(session.stopTimer);
    session.timer = null;
    session.stopTimer = null;
  }

  #release(session) {
    this.#clearTimers(session);
    session.recognition.onstart = null;
    session.recognition.onresult = null;
    session.recognition.onerror = null;
    session.recognition.onend = null;
    if (this.#session === session) this.#session = null;
  }

  #errorMessage(error) {
    const messages = {
      'not-allowed': '麦克风权限被拒绝。请在浏览器网站设置中允许麦克风，再重新开始。',
      'service-not-allowed': '浏览器不允许使用语音识别服务，请检查浏览器设置或换用其他支持的浏览器。',
      'audio-capture': '没有找到可用的麦克风。请检查设备连接，以及系统和浏览器的麦克风权限。',
      'no-speech': '暂时没有听到语音，请靠近麦克风，点击开始后重试。',
      network: '语音服务连接失败，请检查网络后重试。浏览器语音识别可能需要联网。',
      'language-not-supported': '当前语音服务不支持所选语言，请手动切换其他识别语言后重试。',
      aborted: '本次语音识别已中断，点击开始可重试。',
    };
    return messages[error] || '语音识别暂时不可用，请稍后重试，或直接输入文字。';
  }
}
