import assert from 'node:assert/strict';
import { VoiceController } from './voice.mjs';

// Run with: node web/verify-voice.mjs
// These checks simulate browser events; they never access a real microphone,
// send audio, or require browser automation or third-party Node modules.
const originalGlobals = new Map(
  ['SpeechRecognition', 'webkitSpeechRecognition'].map(name => [
    name, Object.getOwnPropertyDescriptor(globalThis, name),
  ]),
);
const controllers = [];
const instances = [];
let checks = 0;

class FakeRecognition {
  constructor() { instances.push(this); }
  start() { this.startCalls = (this.startCalls || 0) + 1; }
  stop() { this.stopCalls = (this.stopCalls || 0) + 1; }
  abort() { this.abortCalls = (this.abortCalls || 0) + 1; }
}

function installRecognition(standard, prefixed) {
  for (const [name, value] of [
    ['SpeechRecognition', standard],
    ['webkitSpeechRecognition', prefixed],
  ]) {
    Object.defineProperty(globalThis, name, {
      value, configurable: true, writable: true,
    });
  }
}

function makeVoice(overrides = {}) {
  const events = { states: [], interims: [], finals: [], ticks: [] };
  const voice = new VoiceController({
    onState: (...args) => events.states.push(args),
    onInterim: text => events.interims.push(text),
    onFinal: text => events.finals.push(text),
    onTick: seconds => events.ticks.push(seconds),
    ...overrides,
  });
  controllers.push(voice);
  return { voice, events };
}

function result(text, isFinal = false) {
  return Object.assign([{ transcript: text }], { isFinal });
}

function queuedHandlers(recognition) {
  return {
    start: recognition.onstart,
    result: recognition.onresult,
    error: recognition.onerror,
    end: recognition.onend,
  };
}

function check(name, run) {
  run();
  checks += 1;
  console.log(`✓ ${name}`);
}

try {
  check('Support detection and construction never start the microphone', () => {
    installRecognition(undefined, undefined);
    const { voice, events } = makeVoice();
    assert.equal(voice.supported, false);
    assert.equal(voice.state, 'idle');
    assert.equal(voice.start(), false);
    assert.equal(voice.state, 'error');
    assert.match(events.states.at(-1)[1], /不支持语音转文字/);

    installRecognition(undefined, FakeRecognition);
    const before = instances.length;
    const prefixed = makeVoice().voice;
    assert.equal(prefixed.supported, true);
    assert.equal(instances.length, before, 'Construction must not instantiate recognition');
    assert.equal(prefixed.start('zh-TW'), true);
    assert.equal(instances.at(-1).lang, 'zh-TW');
    prefixed.cancel();

    installRecognition(FakeRecognition, undefined);
    const standard = makeVoice().voice;
    assert.equal(standard.supported, true);
    assert.equal(standard.start('unsupported-language'), true);
    assert.equal(instances.at(-1).lang, 'zh-CN');
    standard.cancel();
  });

  check('Interim text replaces the draft and finalized text is delivered once', () => {
    const { voice, events } = makeVoice();
    assert.equal(voice.start('zh-HK'), true);
    assert.equal(voice.start(), false, 'A duplicate start must not create another session');
    const recognition = instances.at(-1);
    assert.equal(recognition.lang, 'zh-HK');
    assert.equal(recognition.continuous, true);
    assert.equal(recognition.interimResults, true);
    assert.equal(voice.state, 'starting');
    recognition.onstart();
    assert.equal(voice.state, 'listening');
    assert.equal(events.ticks[0], 0);

    recognition.onresult({ results: [result('她正在')] });
    assert.equal(events.interims.at(-1), '她正在');
    recognition.onresult({ results: [result('她正在写作。', true), result('她很')] });
    recognition.onresult({ results: [result('她正在写作。', true), result('她很勇敢。')] });
    assert.deepEqual(events.finals, ['她正在写作。']);
    assert.equal(events.interims.at(-1), '她很勇敢。');
    recognition.onresult({ results: [result('她正在写作。', true)] });
    assert.equal(events.interims.at(-1), '', 'Removed interim entries must not remain visible');

    recognition.onresult({ results: [result('她正在写作。', true), result('她很勇敢。')] });
    assert.equal(voice.stop(), true);
    assert.equal(voice.stop(), false);
    assert.equal(recognition.stopCalls, 1);
    assert.equal(recognition.abortCalls, undefined, 'Normal stop must allow the final result to arrive');
    assert.equal(voice.state, 'stopping');
    recognition.onresult({ results: [result('她正在写作。', true), result('她很勇敢。', true)] });
    const lateEnd = recognition.onend;
    recognition.onend();
    lateEnd();
    assert.deepEqual(events.finals, ['她正在写作。', '她很勇敢。']);
    assert.equal(events.interims.at(-1), '');
    assert.equal(voice.state, 'idle');
  });

  check('Stop preserves an unfinalized tail once when the provider ends', () => {
    const { voice, events } = makeVoice();
    voice.start();
    const recognition = instances.at(-1);
    recognition.onstart();
    recognition.onresult({ results: [result('她的声音')] });
    voice.stop();
    recognition.onerror({ error: 'aborted' });
    assert.equal(voice.state, 'stopping', 'A provider abort after intentional stop is not an error');
    const lateEnd = recognition.onend;
    recognition.onend();
    lateEnd();
    assert.deepEqual(events.finals, ['她的声音']);
    assert.match(events.states.at(-1)[1], /末尾文字已保留/);
  });

  check('Cancel discards stop tails and queued events, resets UI, and permits a new session', () => {
    const { voice, events } = makeVoice();
    voice.start();
    const recognition = instances.at(-1);
    const stale = queuedHandlers(recognition);
    recognition.onstart();
    recognition.onresult({ results: [result('应被删除的尾句')] });
    voice.stop();
    assert.equal(voice.cancel(), true);
    assert.equal(recognition.abortCalls, 1);
    assert.equal(recognition.onresult, null);
    assert.equal(recognition.onend, null);
    assert.equal(events.interims.at(-1), '');
    assert.equal(events.ticks.at(-1), 0);
    assert.deepEqual(events.states.at(-1), ['idle', '听写已取消。']);
    const snapshot = JSON.stringify(events);
    stale.result({ results: [result('绝不能回填', true)] });
    stale.start();
    stale.error({ error: 'network' });
    stale.end();
    assert.equal(JSON.stringify(events), snapshot, 'Queued old events must emit no callbacks');
    assert.deepEqual(events.finals, []);

    assert.equal(voice.start(), true);
    stale.end();
    assert.equal(voice.state, 'starting', 'An old end event must not stop the new session');
    const nextRecognition = instances.at(-1);
    nextRecognition.onstart();
    nextRecognition.onresult({ results: [result('新的会话', true)] });
    assert.deepEqual(events.finals, ['新的会话']);
    voice.cancel();
    assert.equal(voice.cancel(), false, 'Cancel without a session still resets UI but reports false');
    assert.deepEqual(events.states.at(-1), ['idle', '听写已取消。']);
  });

  check('Cancel also invalidates startup events and cancellation inside a final callback', () => {
    const { voice, events } = makeVoice();
    voice.start();
    const recognition = instances.at(-1);
    const stale = queuedHandlers(recognition);
    assert.equal(voice.cancel(), true);
    stale.start();
    stale.result({ results: [result('已取消启动后的错误回填', true)] });
    stale.end();
    assert.equal(voice.state, 'idle');
    assert.deepEqual(events.finals, []);

    let reentrant;
    const interims = [];
    reentrant = makeVoice({
      onFinal: () => reentrant.cancel(),
      onInterim: text => interims.push(text),
    }).voice;
    reentrant.start();
    instances.at(-1).onresult({ results: [result('触发取消', true), result('不能重新显示')] });
    assert.equal(reentrant.state, 'idle');
    assert.equal(interims.at(-1), '');
  });

  check('Permission and provider errors remain useful after the end event', () => {
    for (const [error, message] of [
      ['not-allowed', /麦克风权限被拒绝/],
      ['service-not-allowed', /不允许使用语音识别服务/],
      ['audio-capture', /没有找到可用的麦克风/],
      ['no-speech', /没有听到语音/],
      ['network', /连接失败/],
      ['language-not-supported', /不支持所选语言/],
    ]) {
      const { voice, events } = makeVoice();
      voice.start();
      const recognition = instances.at(-1);
      recognition.onerror({ error });
      assert.equal(voice.state, 'error');
      assert.match(events.states.at(-1)[1], message);
      recognition.onend();
      assert.equal(voice.state, 'idle');
      assert.match(events.states.at(-1)[1], message);
      assert.deepEqual(events.finals, []);
    }

    class DeniedRecognition extends FakeRecognition {
      start() { throw Object.assign(new Error('Permission denied'), { name: 'NotAllowedError' }); }
    }
    installRecognition(DeniedRecognition, undefined);
    const denied = makeVoice();
    assert.equal(denied.voice.start(), false);
    assert.equal(denied.voice.state, 'error');
    assert.match(denied.events.states.at(-1)[1], /麦克风权限被拒绝/);
    installRecognition(FakeRecognition, undefined);
  });

  check('Destroy blocks queued callbacks and cannot restart the instance', () => {
    const { voice, events } = makeVoice();
    voice.start();
    const recognition = instances.at(-1);
    const stale = queuedHandlers(recognition);
    voice.destroy();
    const snapshot = JSON.stringify(events);
    stale.result({ results: [result('销毁后不能交付', true)] });
    stale.end();
    assert.equal(voice.state, 'idle');
    assert.equal(recognition.abortCalls, 1);
    assert.equal(voice.start(), false);
    assert.equal(voice.cancel(), false);
    assert.equal(JSON.stringify(events), snapshot);
  });

  console.log(`Verified ${checks} speech-controller checks without microphone or network access.`);
} finally {
  for (const voice of controllers) voice.destroy();
  for (const [name, descriptor] of originalGlobals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else delete globalThis[name];
  }
}
