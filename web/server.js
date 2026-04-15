'use strict';

const express    = require('express');
const multer     = require('multer');
const { v4: uuidv4 } = require('uuid');
const path       = require('path');
const fs         = require('fs');
const { spawn }  = require('child_process');

// ─── Config ───────────────────────────────────────────────────────────────────
const PORT        = process.env.PORT || 3000;
const UPLOAD_DIR  = process.env.UPLOAD_DIR  || path.join(__dirname, '../tmp/uploads');
const OUTPUT_DIR  = process.env.OUTPUT_DIR  || path.join(__dirname, '../tmp/outputs');
const SCRIPTS_DIR = process.env.SCRIPTS_DIR || path.join(__dirname, '../scripts');
const PUBLIC_DIR  = path.join(__dirname, '../public');

[UPLOAD_DIR, OUTPUT_DIR].forEach(d => fs.mkdirSync(d, { recursive: true }));

// ─── In-memory build registry ─────────────────────────────────────────────────
// { [buildId]: { status, zipPath, outputDir, apks, aabs, errors, logPath, sseClients } }
const builds = new Map();

// ─── Multer ──────────────────────────────────────────────────────────────────
const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
  filename:    (_req, file, cb) => {
    const safe = file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_');
    cb(null, `${uuidv4()}-${safe}`);
  },
});
const upload = multer({
  storage,
  limits: { fileSize: 512 * 1024 * 1024 }, // 512 MB
  fileFilter: (_req, file, cb) => {
    if (!file.originalname.toLowerCase().endsWith('.zip')) {
      return cb(new Error('Only .zip files are accepted'));
    }
    cb(null, true);
  },
});

// ─── Express app ─────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(PUBLIC_DIR));

// ═════════════════════════════════════════════════════════════════════════════
// POST /api/build  — accept ZIP, start pipeline
// ═════════════════════════════════════════════════════════════════════════════
app.post('/api/build', upload.single('zip'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No ZIP file uploaded' });

  const buildId   = uuidv4();
  const outputDir = path.join(OUTPUT_DIR, buildId);
  const logPath   = path.join(outputDir, 'pipeline.log');
  fs.mkdirSync(outputDir, { recursive: true });

  builds.set(buildId, {
    id:         buildId,
    status:     'RUNNING',
    zipPath:    req.file.path,
    zipName:    req.file.originalname,
    outputDir,
    logPath,
    apks:       [],
    aabs:       [],
    errors:     [],
    startedAt:  Date.now(),
    finishedAt: null,
    sseClients: new Set(),
  });

  res.json({ buildId });

  // Start build asynchronously
  _runBuild(buildId);
});

// ═════════════════════════════════════════════════════════════════════════════
// GET /api/build/:id/stream  — SSE real-time log stream
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/build/:id/stream', (req, res) => {
  const build = builds.get(req.params.id);
  if (!build) return res.status(404).json({ error: 'Build not found' });

  res.setHeader('Content-Type',  'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection',    'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  // Send existing log tail first (catch-up for reconnects)
  if (fs.existsSync(build.logPath)) {
    const tail = fs.readFileSync(build.logPath, 'utf8');
    tail.split('\n').forEach(line => {
      if (line) res.write(`data: ${JSON.stringify({ type: 'log', line })}\n\n`);
    });
  }

  // If already finished, send result and close
  if (build.status !== 'RUNNING') {
    res.write(`data: ${JSON.stringify({ type: 'result', build: _buildSummary(build) })}\n\n`);
    return res.end();
  }

  // Register live client
  build.sseClients.add(res);
  req.on('close', () => build.sseClients.delete(res));
});

// ═════════════════════════════════════════════════════════════════════════════
// GET /api/build/:id  — status + artifact list
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/build/:id', (req, res) => {
  const build = builds.get(req.params.id);
  if (!build) return res.status(404).json({ error: 'Build not found' });
  res.json(_buildSummary(build));
});

// ═════════════════════════════════════════════════════════════════════════════
// GET /api/build/:id/download/:filename  — serve artifact
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/build/:id/download/:filename', (req, res) => {
  const build = builds.get(req.params.id);
  if (!build) return res.status(404).json({ error: 'Build not found' });

  // Prevent path traversal
  const filename = path.basename(req.params.filename);
  const filePath = path.join(build.outputDir, filename);

  if (!filePath.startsWith(build.outputDir) || !fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'Artifact not found' });
  }

  res.download(filePath, filename);
});

// ─── Internal helpers ─────────────────────────────────────────────────────────
function _buildSummary(b) {
  const duration = b.finishedAt
    ? Math.round((b.finishedAt - b.startedAt) / 1000)
    : Math.round((Date.now() - b.startedAt) / 1000);

  return {
    id:       b.id,
    status:   b.status,
    zipName:  b.zipName,
    apks:     b.apks.map(f => ({ name: path.basename(f), size: _fileSize(f) })),
    aabs:     b.aabs.map(f => ({ name: path.basename(f), size: _fileSize(f) })),
    errors:   b.errors,
    duration,
    startedAt:  b.startedAt,
    finishedAt: b.finishedAt,
  };
}

function _fileSize(p) {
  try {
    const bytes = fs.statSync(p).size;
    if (bytes < 1024)       return `${bytes} B`;
    if (bytes < 1048576)    return `${(bytes/1024).toFixed(1)} KB`;
    return `${(bytes/1048576).toFixed(1)} MB`;
  } catch { return '?' }
}

function _broadcast(build, event) {
  const msg = `data: ${JSON.stringify(event)}\n\n`;
  build.sseClients.forEach(client => {
    try { client.write(msg); } catch { build.sseClients.delete(client); }
  });
}

function _log(build, line) {
  fs.appendFileSync(build.logPath, line + '\n');
  _broadcast(build, { type: 'log', line });
}

// ─── Run the build shell pipeline ────────────────────────────────────────────
function _runBuild(buildId) {
  const build = builds.get(buildId);

  _log(build, `[Builder] Starting build ${buildId}`);
  _log(build, `[Builder] Source: ${build.zipName}`);
  _log(build, `[Builder] Output: ${build.outputDir}`);
  _log(build, '─'.repeat(60));

  const env = {
    ...process.env,
    OUTPUT_DIR:   build.outputDir,
    WORK_DIR:     `/tmp/android_build_${buildId}`,
    ANDROID_HOME: process.env.ANDROID_HOME || `${process.env.HOME}/android-sdk`,
    // Signing (optional — passed through from server env)
    KEYSTORE_PATH:  process.env.KEYSTORE_PATH  || '',
    KEYSTORE_ALIAS: process.env.KEYSTORE_ALIAS || '',
    KEYSTORE_PASS:  process.env.KEYSTORE_PASS  || '',
  };

  const proc = spawn(
    'bash',
    [path.join(SCRIPTS_DIR, 'build.sh'), build.zipPath],
    { env, stdio: ['ignore', 'pipe', 'pipe'] }
  );

  const onLine = chunk => {
    chunk.toString().split('\n').forEach(line => {
      if (line) _log(build, line);
    });
  };

  proc.stdout.on('data', onLine);
  proc.stderr.on('data', onLine);

  proc.on('close', exitCode => {
    _log(build, '─'.repeat(60));
    _log(build, `[Builder] Process exited with code ${exitCode}`);

    // Collect artifacts from outputDir
    try {
      const files = fs.readdirSync(build.outputDir);
      build.apks = files
        .filter(f => f.endsWith('.apk'))
        .map(f => path.join(build.outputDir, f));
      build.aabs = files
        .filter(f => f.endsWith('.aab'))
        .map(f => path.join(build.outputDir, f));
    } catch { /* no artifacts */ }

    // Parse JSON result from log
    try {
      const logText  = fs.readFileSync(build.logPath, 'utf8');
      const jsonMatch = logText.match(/\{[\s\S]*?"status"\s*:\s*"(SUCCESS|PARTIAL|FAILED)"[\s\S]*?\}/);
      if (jsonMatch) {
        const result = JSON.parse(jsonMatch[0]);
        build.status = result.status;
        build.errors = result.errors || [];
        // Prefer JSON-reported paths if they exist on disk
        if (result.apk?.length) {
          const resolved = result.apk.filter(p => fs.existsSync(p));
          if (resolved.length) build.apks = resolved;
        }
        if (result.aab?.length) {
          const resolved = result.aab.filter(p => fs.existsSync(p));
          if (resolved.length) build.aabs = resolved;
        }
      } else {
        build.status = exitCode === 0 ? (build.aabs.length ? 'SUCCESS' : build.apks.length ? 'PARTIAL' : 'FAILED') : 'FAILED';
      }
    } catch {
      build.status = exitCode === 0 ? 'PARTIAL' : 'FAILED';
    }

    build.finishedAt = Date.now();
    _log(build, `[Builder] Status: ${build.status}`);

    // Notify all SSE clients with final result
    _broadcast(build, { type: 'result', build: _buildSummary(build) });
    build.sseClients.forEach(c => { try { c.end(); } catch {} });
    build.sseClients.clear();

    // Cleanup uploaded ZIP
    try { fs.unlinkSync(build.zipPath); } catch {}
  });
}

// ─── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`\n  Android Builder UI ready`);
  console.log(`  http://localhost:${PORT}\n`);
});
