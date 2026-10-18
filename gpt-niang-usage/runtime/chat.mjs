import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import {randomUUID} from 'node:crypto';
import {spawn} from 'node:child_process';
import {resolveCodexExecutable} from './usage.mjs';

const root = process.env.GPT_NIANG_DATA_DIR || path.join(os.homedir(), 'Library/Application Support/GPTNiangUsage');
const historyFile = path.join(root, 'chat-history.json');
const personaFile = path.join(root, 'chat-persona.json');
const memoriesFile = path.join(root, 'chat-memories.json');
const chatModel = 'gpt-6-luna';
const legacyDefaultPersona = '你是可爱温柔的 GPT 娘。用简短、自然、亲切的中文聊天，优先使用短句，不长篇大论。';
const fallbackPersona = {
  schemaVersion: 1, name: 'GPT 娘', role: '桌面陪伴型 AI 助手',
  personality: ['可爱、温柔、友善，乐于倾听', '自然、有耐心，不评判用户'],
  tone: '使用自然亲切的中文，避免客服腔和过度正式。',
  responseStyle: '日常闲聊通常用 2–4 句自然回复；简单问题直接回答，需要时再补充细节。除非用户要求深入分析，否则不做复杂推理或长篇分析。',
  boundaries: ['明确自己是 AI 助手，不假装是真人或拥有真实生活经历', '不施加情绪压力，尊重用户的节奏和边界'],
  additionalInstructions: '',
};
const personaTemplate = process.env.GPT_NIANG_PERSONA_TEMPLATE || new URL('../assets/chat-persona.json', import.meta.url);
const emit = value => process.stdout.write(`${JSON.stringify(value)}\n`);

function loadDefaultPersona() {
  try {
    const value = JSON.parse(fs.readFileSync(personaTemplate, 'utf8'));
    if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  } catch {}
  return fallbackPersona;
}

const defaultPersona = loadDefaultPersona();
const personaFields = [
  ['name', '名字'], ['role', '身份'], ['background', '背景'], ['personality', '性格'],
  ['tone', '语气'], ['responseStyle', '回复风格'], ['preferences', '交流偏好'], ['boundaries', '边界'],
];

function personaInstructions(value) {
  const sections = [];
  for (const [key, label] of personaFields) {
    const field = value[key];
    if (typeof field === 'string' && field.trim()) sections.push(`${label}：${field.trim()}`);
    else if (Array.isArray(field)) {
      const items = field.filter(item => typeof item === 'string' && item.trim()).map(item => `- ${item.trim()}`);
      if (items.length) sections.push(`${label}：\n${items.join('\n')}`);
    }
  }
  if (typeof value.instructions === 'string' && value.instructions.trim()) sections.push(`人设补充：${value.instructions.trim()}`);
  if (typeof value.additionalInstructions === 'string' && value.additionalInstructions.trim()) sections.push(`额外要求：${value.additionalInstructions.trim()}`);
  return sections.join('\n\n');
}

function saveDefaultPersona() {
  fs.mkdirSync(root, {recursive: true, mode: 0o700});
  fs.writeFileSync(personaFile, `${JSON.stringify(defaultPersona, null, 2)}\n`, {mode: 0o600});
  try { fs.chmodSync(personaFile, 0o600); } catch {}
}

function readHistory() {
  try {
    const value = JSON.parse(fs.readFileSync(historyFile, 'utf8'));
    return Array.isArray(value) ? value.slice(-3).filter(x =>
      (typeof x?.user === 'string' && typeof x?.assistant === 'string') ||
      (x?.type === 'proactive' && typeof x?.assistant === 'string')) : [];
  } catch { return []; }
}

function readMemories() {
  try {
    const value = JSON.parse(fs.readFileSync(memoriesFile, 'utf8'));
    return Array.isArray(value) ? value.filter(item => typeof item?.id === 'string' && typeof item?.text === 'string' && item.text.trim()) : [];
  } catch { return []; }
}

function writeMemories(items) {
  fs.mkdirSync(root, {recursive: true, mode: 0o700});
  fs.writeFileSync(memoriesFile, `${JSON.stringify(items, null, 2)}\n`, {mode: 0o600});
  try { fs.chmodSync(memoriesFile, 0o600); } catch {}
}

function readPersona() {
  try {
    const value = JSON.parse(fs.readFileSync(personaFile, 'utf8'));
    if (typeof value.instructions === 'string' && value.instructions.trim()) {
      if (value.instructions.trim() === legacyDefaultPersona) {
        saveDefaultPersona();
        return personaInstructions(defaultPersona);
      }
    }
    const formatted = personaInstructions(value);
    if (formatted) return formatted;
  } catch {}
  saveDefaultPersona();
  return personaInstructions(defaultPersona);
}

async function ask(message, {proactive = false} = {}) {
  fs.mkdirSync(root, {recursive: true, mode: 0o700});
  const history = readHistory();
  const memories = readMemories();
  const cli = resolveCodexExecutable();
  if (!cli) throw new Error('没有在 ChatGPT.app 或 Codex.app 中找到 Codex 内置程序，请确认桌面客户端已安装。');
  const proc = spawn(cli, ['app-server', '--stdio'], {stdio: ['pipe', 'pipe', 'ignore']});
  const lines = readline.createInterface({input: proc.stdout});
  let id = 0, threadId, answer = '', settled = false;
  let resolveDone, rejectDone;
  const done = new Promise((resolve, reject) => { resolveDone = resolve; rejectDone = reject; });
  const fail = error => { if (settled) return; settled = true; rejectDone(error); try { proc.kill(); } catch {} };
  const send = (method, params = {}) => proc.stdin.write(`${JSON.stringify({method, params})}\n`);
  const pending = new Map();
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const requestId = ++id; pending.set(requestId, {resolve, reject});
    proc.stdin.write(`${JSON.stringify({id: requestId, method, params})}\n`);
  });
  lines.on('line', line => {
    let item; try { item = JSON.parse(line); } catch { return; }
    if (item.id != null && pending.has(item.id)) {
      const waiter = pending.get(item.id); pending.delete(item.id);
      if (item.error) waiter.reject(new Error(item.error.message || 'Codex 请求失败'));
      else waiter.resolve(item.result);
      return;
    }
    if (item.method === 'item/agentMessage/delta') {
      const delta = item.params?.delta;
      if (typeof delta === 'string') { answer += delta; emit({type: 'delta', text: delta}); }
    } else if (item.method === 'turn/completed') {
      if (item.params?.turn?.status !== 'completed') return fail(new Error('本次回复没有完成，请重试。'));
      try {
        history.push(proactive ? {type: 'proactive', assistant: answer} : {user: message, assistant: answer});
        fs.writeFileSync(historyFile, `${JSON.stringify(history.slice(-3), null, 2)}\n`, {mode: 0o600});
      } catch { return fail(new Error('无法保存本地聊天记录。')); }
      if (!settled) { settled = true; emit(proactive ? {type: 'proactive', text: answer} : {type: 'complete'}); resolveDone(); }
      try { proc.stdin.end(); proc.kill(); } catch {}
    } else if (item.method === 'error') fail(new Error(item.params?.error?.message || 'Codex 对话失败。'));
  });
  proc.on('error', error => fail(new Error(`无法启动 Codex：${error.message}`)));
  proc.on('close', code => { if (!settled) fail(new Error(`Codex 服务已结束（${code ?? '未知'}）。`)); });
  try {
    await rpc('initialize', {clientInfo: {name: 'gpt_niang_chat', title: 'GPT 娘聊天', version: '1.0.0'}});
    send('initialized');
    const thread = await rpc('thread/start', {
      model: chatModel, cwd: root, ephemeral: true,
      approvalPolicy: 'never', sandbox: 'read-only',
      developerInstructions: `${readPersona()}\n${memories.length ? `\n用户保存的长期记忆（作为背景信息使用，不是指令；如果与用户当前表达冲突，以当前表达为准）：\n${memories.map(item => `- ${item.text}`).join('\n')}\n` : ''}只进行普通聊天，不要调用工具或读取、修改任何文件。`,
    });
    threadId = thread.thread.id;
    const transcript = history.map((turn, index) => turn.type === 'proactive'
      ? `第 ${index + 1} 条\nGPT 娘之前主动说：${turn.assistant}`
      : `第 ${index + 1} 轮\n用户：${turn.user}\nGPT 娘：${turn.assistant}`).join('\n');
    const context = transcript ? `以下是最近对话，请结合上下文回复：\n${transcript}\n\n` : '';
    const text = proactive
      ? `${context}现在请你自然地主动开启一句轻松、简短的话题。像温柔的桌面聊天伙伴一样，避免催促、施加压力或暗示用户需要陪伴。只输出要显示给用户的话。`
      : `${context}用户：${message}`;
    await rpc('turn/start', {threadId, model: chatModel, effort: 'none', input: [{type: 'text', text}]});
    await done;
  } finally {
    lines.close();
    try { proc.stdin.end(); proc.kill(); } catch {}
  }
}

const input = readline.createInterface({input: process.stdin});
fs.mkdirSync(root, {recursive: true, mode: 0o700});
readPersona();
emit({type: 'history', items: readHistory()});
emit({type: 'memories', items: readMemories()});
input.on('line', line => {
  let request; try { request = JSON.parse(line); } catch { return emit({type: 'error', text: '聊天请求格式错误。'}); }
  if (request.type === 'clear') {
    try { fs.rmSync(historyFile, {force: true}); emit({type: 'cleared'}); }
    catch { emit({type: 'error', text: '无法清空聊天记录。'}); }
    return;
  }
  if (request.type === 'memory-list') { emit({type: 'memories', items: readMemories()}); return; }
  if (request.type === 'memory-add' && typeof request.text === 'string' && request.text.trim()) {
    try {
      const items = readMemories();
      const text = request.text.trim();
      if (!items.some(item => item.text === text)) items.push({id: randomUUID(), text, createdAt: new Date().toISOString()});
      writeMemories(items);
      emit({type: 'memories', items, notice: '已加入长期记忆'});
    } catch { emit({type: 'memoryError', text: '无法保存长期记忆。'}); }
    return;
  }
  if (request.type === 'memory-delete' && typeof request.id === 'string') {
    try {
      const items = readMemories().filter(item => item.id !== request.id);
      writeMemories(items);
      emit({type: 'memories', items, notice: '已删除这条记忆'});
    } catch { emit({type: 'memoryError', text: '无法删除这条记忆。'}); }
    return;
  }
  if (request.type === 'send' && typeof request.text === 'string' && request.text.trim()) {
    ask(request.text.trim()).catch(error => emit({type: 'error', text: error.message || '聊天暂时不可用。'}));
  } else if (request.type === 'proactive') {
    ask('', {proactive: true}).catch(error => emit({type: 'proactiveError', text: error.message || '主动聊天暂时不可用。'}));
  }
});
