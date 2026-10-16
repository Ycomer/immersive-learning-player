// Exercise the installed, signed Wave Subs release's unmodified domain pipeline.
// Only the Electron shell bootstrap is omitted from a separate evaluation copy.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';

const root = resolve('tools/wavesubs-evaluation');
const resources = '/Applications/Wave Subs.app/Contents/Resources';
const packed = await readFile(join(resources, 'app.asar'));
const headerSize = packed.readUInt32LE(4);
const header = JSON.parse(packed.subarray(16, 16 + packed.readUInt32LE(12)));
const entry = header.files.out.files.main.files['index.js'];
const start = 8 + headerSize + Number(entry.offset);
const original = packed.subarray(start, start + entry.size);
const bundleHash = createHash('sha256').update(original).digest('hex');
if (bundleHash !== entry.integrity.hash) throw new Error('Installed code integrity mismatch');
let code = original.toString();
code = code.slice(code.indexOf('\n') + 1, code.indexOf('protocol.registerSchemesAsPrivileged(['));
code += '\nexport { runSubtitleJob, setBundledBinDirs, LlamaServerManager, LocalLlamaProvider, JobStore };\n';
const corePath = join(root, 'release-core.mjs');
await writeFile(corePath, code);
const core = await import(corePath);
core.setBundledBinDirs([join(resources, 'vendor/bin')]);

const nativeFetch = globalThis.fetch;
const connections = new Set();
globalThis.fetch = async (request, init) => {
  const url = new URL(typeof request === 'string' ? request : request.url ?? request);
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
    throw new Error(`Evaluation forbids outbound requests: ${url.origin}`);
  }
  connections.add(url.origin);
  return nativeFetch(request, init);
};
const mode = process.argv[2] ?? 'asr';
const limit = Number(process.argv[3] ?? Infinity);
const manifest = JSON.parse(await readFile(join(root, 'evaluation-manifest.json'), 'utf8'));
const modelRoot = join(homedir(), 'Library/Application Support/Wave Subs/models');
const cache = join(root, 'cache');
const manager = new core.LlamaServerManager();
const store = new core.JobStore(cache);
const records = [];
const reportPath = join(root, `${mode}-results.json`);
const report = () => ({
  installedVersion: '1.0.9', installedBundleSHA256: bundleHash,
  method: 'installed release domain pipeline, Electron UI bootstrap omitted in evaluation copy',
  speechModel: 'ggml-large-v3.bin',
  translationModel: mode === 'translate' ? 'Qwen3-8B-Q4_K_M.gguf' : null,
  source: manifest.referenceSource, outboundRequestsForbidden: true,
  contactedOrigins: [...connections], semanticAccuracyVerified: false,
  cases: records,
});
await mkdir(join(root, 'exports'), { recursive: true });
const selected = manifest.cases.filter(item => !process.argv[4] || item.id === process.argv[4]).slice(0, limit);
try {
  for (const [index, item] of selected.entries()) {
    const begun = performance.now();
    let lastStage;
    console.log(`START ${index + 1}/${selected.length} ${item.id}`);
    try {
      const result = await core.runSubtitleJob({
        input: item.file,
        source: { kind: 'asr' },
        modelPath: join(modelRoot, 'ggml-large-v3.bin'),
        language: 'ja',
        vadModelPath: join(resources, 'vendor/vad/ggml-silero-v5.1.2.bin'),
        cacheDir: cache,
        refreshCache: mode === 'asr',
        outputDir: join(root, 'exports'),
        output: { format: 'srt', content: mode === 'translate' ? 'bilingual' : 'original' },
        translate: mode === 'translate' ? {
          provider: new core.LocalLlamaProvider(manager, join(modelRoot, 'llm/Qwen3-8B-Q4_K_M.gguf'), 'zh'),
          targetLanguage: 'zh', engineId: 'local|Qwen3-8B-Q4_K_M.gguf',
        } : undefined,
        onProgress(p) {
          if (p.stage !== lastStage) {
            console.log(`  ${item.id}: ${p.stage} ${p.percent}%`);
            lastStage = p.stage;
          }
        },
      });
      const cached = await store.load(item.file);
      records.push({ ...item, processingSeconds: (performance.now() - begun) / 1000,
        result, hypothesis: (cached?.cues ?? []).map(c => c.text).join(''),
        cues: cached?.cues ?? [], duration: cached?.durationSec,
      });
      console.log(`DONE ${item.id}: ${result.cueCount} cues, ${records.at(-1).processingSeconds.toFixed(1)}s`);
    } catch (error) {
      records.push({ ...item, processingSeconds: (performance.now() - begun) / 1000,
        error: String(error.stack ?? error), hypothesis: '', cues: [],
      });
      console.log(`ERROR ${item.id}: ${error.message}`);
    }
    await writeFile(reportPath, JSON.stringify(report(), null, 2));
  }
} finally {
  manager.stop();
  await writeFile(reportPath, JSON.stringify(report(), null, 2));
}
console.log(`SAVED ${reportPath}`);
