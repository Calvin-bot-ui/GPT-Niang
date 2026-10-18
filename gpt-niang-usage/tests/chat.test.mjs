import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import readline from 'node:readline';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chat = path.join(root, 'runtime/chat.mjs');

test('chat streams, keeps only the latest three rounds, reads persona JSON and clears history', async t => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'gpt-niang-chat-'));
  t.after(() => fs.rmSync(temporary, {recursive: true, force: true}));
  const bin = path.join(temporary, 'bin'); fs.mkdirSync(bin);
  const capture = path.join(temporary, 'requests.jsonl');
  const personaPath = path.join(temporary, 'chat-persona.json');
  fs.writeFileSync(personaPath, JSON.stringify({instructions: '你是可爱温柔的 GPT 娘。用简短、自然、亲切的中文聊天，优先使用短句，不长篇大论。'}));
  const fakeServer = path.join(bin, 'codex');
  fs.writeFileSync(fakeServer, `#!/usr/bin/env ${process.execPath}\n` + `
import fs from 'node:fs';
import readline from 'node:readline';
const capture = process.env.GPT_NIANG_TEST_CAPTURE;
const lines = readline.createInterface({input: process.stdin});
const write = value => process.stdout.write(JSON.stringify(value) + '\\n');
let developerInstructions = '';
lines.on('line', line => {
  let message; try { message = JSON.parse(line); } catch { return; }
  if (message.id == null) return;
  if (message.method === 'initialize') write({id: message.id, result: {}});
  else if (message.method === 'thread/start') { developerInstructions = message.params.developerInstructions; write({id: message.id, result: {thread: {id: 'test-thread'}}}); }
  else if (message.method === 'turn/start') {
    fs.appendFileSync(capture, JSON.stringify({params: message.params, developerInstructions}) + '\\n');
    write({id: message.id, result: {}});
    write({method: 'item/agentMessage/delta', params: {delta: '测试'}});
    write({method: 'turn/completed', params: {turn: {status: 'completed'}}});
  }
});
`, {mode: 0o700});

  const env = {...process.env, GPT_NIANG_DATA_DIR: temporary, GPT_NIANG_TEST_CAPTURE: capture,
    PATH: [bin, process.env.PATH || ''].join(path.delimiter)};
  delete env.GPT_NIANG_CODEX_APP;
  delete env.CODEX_CLI_PATH;
  // Keep this test isolated from any real desktop CLI installed on the host.
  env.GPT_NIANG_CODEX_APP = path.join(temporary, 'missing.app');
  const proc = spawn(process.execPath, [chat], {env, stdio: ['pipe', 'pipe', 'pipe']});
  const events = [];
  const waiters = new Map();
  const output = readline.createInterface({input: proc.stdout});
  output.on('line', line => {
    let event; try { event = JSON.parse(line); } catch { return; }
    events.push(event);
    const pending = waiters.get(event.type) ?? [];
    for (const waiter of pending) waiter(event);
    if (pending.length) event.__claimed = true;
    waiters.delete(event.type);
  });
  const waitFor = type => {
    const existing = events.find(event => event.type === type && !event.__claimed);
    if (existing) { existing.__claimed = true; return Promise.resolve(existing); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${type}`)), 15000);
      const list = waiters.get(type) ?? [];
      list.push(event => { clearTimeout(timer); resolve(event); }); waiters.set(type, list);
    });
  };
  const send = value => proc.stdin.write(`${JSON.stringify(value)}\n`);
  const respond = async text => {
    const delta = waitFor('delta');
    const complete = waitFor('complete');
    send({type: 'send', text});
    assert.equal((await delta).text, '测试');
    const event = await complete;
    return event;
  };
  t.after(() => { output.close(); if (!proc.killed) proc.kill(); });

  const initial = await waitFor('history');
  assert.deepEqual(initial.items, []);
  assert.deepEqual((await waitFor('memories')).items, []);
  const migratedPersona = JSON.parse(fs.readFileSync(personaPath, 'utf8'));
  assert.equal(migratedPersona.name, 'GPT 娘');
  assert.ok(migratedPersona.responseStyle.includes('2–4 句'));
  assert.ok(!migratedPersona.responseStyle.includes('优先使用短句'));
  fs.writeFileSync(personaPath, JSON.stringify({
    name: '小星', role: '用户的聊天搭档', personality: ['好奇', '耐心'], tone: '轻松自然',
    responseStyle: '自然地多聊几句', additionalInstructions: '测试人设：请保持简短。',
  }));

  for (const text of ['第1轮', '第2轮', '第3轮', '第4轮', '第5轮']) await respond(text);
  const saved = JSON.parse(fs.readFileSync(path.join(temporary, 'chat-history.json'), 'utf8'));
  assert.deepEqual(saved.map(turn => turn.user), ['第3轮', '第4轮', '第5轮']);
  const requests = fs.readFileSync(capture, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  assert.equal(requests[0].params.model, 'gpt-6-luna');
  assert.equal(requests[0].params.effort, 'none');
  assert.ok(requests[0].developerInstructions.includes('名字：小星'));
  assert.ok(requests[0].developerInstructions.includes('回复风格：自然地多聊几句'));
  assert.ok(requests[0].developerInstructions.includes('额外要求：测试人设'));
  assert.ok(requests[1].params.input[0].text.includes('第1轮'));
  assert.ok(requests[4].params.input[0].text.includes('第2轮'));
  assert.ok(!requests[4].params.input[0].text.includes('第1轮'));

  const proactive = waitFor('proactive'); send({type: 'proactive'});
  const proactiveEvent = await proactive;
  assert.equal(proactiveEvent.type, 'proactive');
  assert.equal(proactiveEvent.text, '测试');
  const afterProactive = JSON.parse(fs.readFileSync(path.join(temporary, 'chat-history.json'), 'utf8'));
  assert.deepEqual(afterProactive.map(turn => turn.type === 'proactive' ? '主动消息' : turn.user), ['第4轮', '第5轮', '主动消息']);
  const proactiveRequest = fs.readFileSync(capture, 'utf8').trim().split('\n').map(line => JSON.parse(line)).at(-1);
  assert.ok(proactiveRequest.params.input[0].text.includes('主动开启一句轻松'));

  const added = waitFor('memories'); send({type: 'memory-add', text: '我喜欢海边散步'});
  const memoryList = await added;
  assert.equal(memoryList.items.length, 1);
  assert.equal(memoryList.items[0].text, '我喜欢海边散步');
  assert.ok(memoryList.items[0].id);
  const memoriesPath = path.join(temporary, 'chat-memories.json');
  assert.deepEqual(JSON.parse(fs.readFileSync(memoriesPath, 'utf8')).map(item => item.text), ['我喜欢海边散步']);
  const duplicate = waitFor('memories'); send({type: 'memory-add', text: '我喜欢海边散步'});
  assert.equal((await duplicate).items.length, 1);
  await respond('记住我喜欢什么？');
  const memoryAwareRequest = fs.readFileSync(capture, 'utf8').trim().split('\n').map(line => JSON.parse(line)).at(-1);
  assert.ok(memoryAwareRequest.developerInstructions.includes('用户保存的长期记忆'));
  assert.ok(memoryAwareRequest.developerInstructions.includes('我喜欢海边散步'));
  const beforeClearHistory = JSON.parse(fs.readFileSync(path.join(temporary, 'chat-history.json'), 'utf8'));
  assert.equal(beforeClearHistory.length, 3);
  const deleted = waitFor('memories'); send({type: 'memory-delete', id: memoryList.items[0].id});
  assert.deepEqual((await deleted).items, []);
  assert.deepEqual(JSON.parse(fs.readFileSync(memoriesPath, 'utf8')), []);
  assert.equal(JSON.parse(fs.readFileSync(path.join(temporary, 'chat-history.json'), 'utf8')).length, 3);

  const cleared = waitFor('cleared'); send({type: 'clear'}); await cleared;
  assert.equal(fs.existsSync(path.join(temporary, 'chat-history.json')), false);
});
