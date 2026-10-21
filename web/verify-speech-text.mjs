import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { feminineSpeechText, joinSpeechSegments, processSpeechText } from "./speech-text.mjs";
import { prepareRules, rewriteText } from "./rewrite.mjs";

let checks = 0;
function equal(actual, expected, name) {
  assert.deepEqual(actual, expected, name);
  checks += 1;
}
const examples = [
  ["", ""],
  ["他它她他们它们牠祂", "她她她她们她们牠祂"],
  ["He told him it works. he/him/it IT", "He told him it works. he/him/it IT"],
  ["他在GitHub用SwiftUI写API，it works on iPhone和Mac。", "她在GitHub用SwiftUI写API，it works on iPhone和Mac。"],
  ["她用Xcode，Python、JavaScript和TypeScript。", "她用Xcode，Python、JavaScript和TypeScript。"],
  ["他贴了 https://他.example/它?q=他#它 。它很好", "她贴了 https://他.example/它?q=他#它 。她很好"],
  ["他看 https://example.com/它。它在这里", "她看 https://example.com/它。她在这里"],
  ["它在 www.例子.公司/他", "她在 www.例子.公司/他"],
  ["它给 他@例子.公司 和 User+It@EXAMPLE.com 发信", "她给 他@例子.公司 和 User+It@EXAMPLE.com 发信"],
  ["它看 `他/它/he/it`，他回答", "她看 `他/它/he/it`，她回答"],
  ["它看 ``他`它``，他回答", "她看 ``他`它``，她回答"],
  ["他看\n```swift\nlet 他 = 它\n```\n它答", "她看\n```swift\nlet 他 = 它\n```\n她答"],
  ["他看\n~~~text\n他它\n~~~\n它答", "她看\n~~~text\n他它\n~~~\n她答"],
  ["他 ```未关闭的它\n他", "她 ```未关闭的它\n他"],
  ["他 `它\n它", "她 `它\n她"],
  ["🙂他 café e\u0301 它", "🙂她 café e\u0301 她"],
  ["他\n\t它  她", "她\n\t她  她"],
];
for (const [source, expected] of examples) {
  equal(feminineSpeechText(source), expected, source);
  equal(feminineSpeechText(expected), expected, "idempotence");
}
const joins = [
  ["", "world", "world"], ["Hello", "", "Hello"],
  ["Hello", "world", "Hello world"], ["GitHub", "API", "GitHub API"],
  ["Xcode", "26", "Xcode 26"], ["api_v2", "works", "api_v2 works"],
  ["Hello ", "world", "Hello world"], ["Hello ", " world", "Hello  world"],
  ["a\t", "b", "a\tb"], ["a\n", "b", "a\nb"],
  ["她", "们", "她们"], ["她用", "GitHub", "她用GitHub"],
  ["GitHub", "很好", "GitHub很好"], ["Hello", ", world", "Hello, world"],
  ["Hello,", "world", "Hello,world"], ["(", "API", "(API"],
  ["https://", "example.com", "https://example.com"],
  ["user@", "example.com", "user@example.com"], ["🙂", "API", "🙂API"],
];
for (const [left, right, expected] of joins) {
  equal(joinSpeechSegments(left, right), expected, "join " + left + "|" + right);
}
const seen = [];
equal(processSpeechText("他 `它` 它 https://他.example/它", { rewrite: (value) => {
  seen.push(value);
  return value.replaceAll("他", "她");
} }), "她 `它` 她 https://他.example/它", "callback cannot repollute protected spans");
equal(seen, ["他 ", " 它 "], "only plain spans reach rewrite");
equal(processSpeechText("这件事", { rewrite: () => "它" }), "她", "rewrite then pronouns");
equal(processSpeechText("https://他.example/它", { rewrite: () => {
  throw new Error("Protected URL was sent to rewrite.");
} }), "https://他.example/它", "all-protected input");
assert.throws(() => feminineSpeechText(null), TypeError); checks += 1;
assert.throws(() => processSpeechText("他", { rewrite: false }), TypeError); checks += 1;
assert.throws(() => processSpeechText("他", { rewrite: () => undefined }), TypeError); checks += 1;
assert.throws(() => joinSpeechSegments("hello", 1), TypeError); checks += 1;

// Use the production web wording engine and the shared production rule data.
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const data = JSON.parse(await readFile(resolve(root, "ios/Keyboard/Resources/rules.json"), "utf8"));
const rules = prepareRules({ format: "her-words-web-rules", rules: data.rules });
const realRewrite = (value) => rewriteText(value, rules).text;
equal(processSpeechText("他很奸诈，它在这里，链接 https://他.example/它 和代码 `他很奸诈它`", { rewrite: realRewrite }),
  "她很狡诈，她在这里，链接 https://他.example/它 和代码 `他很奸诈它`", "real production rewrite with protected spans");
equal(processSpeechText("它有能力", { rewrite: (value) => value.replaceAll("他", "她") }),
  "她有能力", "speech pronouns independent of wording mode");
console.log("PASS " + checks + " JavaScript speech text checks");
