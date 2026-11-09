#!/usr/bin/env node
/**
 * hashchain.js — SA 分布式测试任务
 *
 * 算法：SHA-256 链
 *     h(0) = SHA256(seed)
 *     h(i) = SHA256(h(i-1) || i)      i = 1..N
 *
 * 为什么用这个算法
 *   1. 完全确定：10 台机必须算出完全相同的结果，任何分歧立刻可见
 *   2. 无法并行：h(i) 依赖 h(i-1)，测的是纯单核串行性能，不受多核干扰
 *   3. 可定位分歧：每 10000 步存一个校验点，能精确定位从哪步开始不同
 *   4. 无外部依赖：不碰网络、不碰磁盘（除最后写文件），排除干扰
 *
 * 输出：一个 JSON，含结果哈希、校验点、耗时、机器环境指纹
 *
 * 用法：
 *    node hashchain.js --out result.json [--steps 1000000] [--seed xxx]
 */
'use strict'

const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')

function arg(name, def) {
  const i = process.argv.indexOf('--' + name)
  if (i < 0 || i + 1 >= process.argv.length) return def
  return process.argv[i + 1]
}

const SEED = arg('seed', 'sa-dist-test-2026-11-10')
const STEPS = parseInt(arg('steps', '1000000'), 10)
const OUT = arg('out', 'hashchain-result.json')
const CHECKPOINT_EVERY = parseInt(arg('checkpoint', '10000'), 10)

// ---- 环境指纹：用于事后分辨结果差异是否来自环境 ----
function cpuModel() {
  const cpus = os.cpus()
  return cpus && cpus.length ? cpus[0].model.trim() : 'unknown'
}

const env = {
  hostname: os.hostname(),
  platform: os.platform(),
  arch: os.arch(),
  cpu: cpuModel(),
  cores: os.cpus().length,
  totalMemMB: Math.round(os.totalmem() / 1024 / 1024),
  nodeVersion: process.version,
}

// ---- 计算 ----
const startedAt = new Date()
const t0 = process.hrtime.bigint()

// 8 字节小端计数器缓冲，避免每步分配
const counter = Buffer.alloc(8)
let h = crypto.createHash('sha256').update(SEED, 'utf8').digest()

const checkpoints = []
if (CHECKPOINT_EVERY > 0) {
  checkpoints.push({ step: 0, hash: h.toString('hex') })
}

for (let i = 1; i <= STEPS; i++) {
  // counter = i 的小端 64 位表示
  const hi = Math.floor(i / 0x100000000)
  const lo = i >>> 0
  counter.writeUInt32LE(lo, 0)
  counter.writeUInt32LE(hi, 4)

  h = crypto.createHash('sha256').update(h).update(counter).digest()

  if (CHECKPOINT_EVERY > 0 && i % CHECKPOINT_EVERY === 0) {
    checkpoints.push({ step: i, hash: h.toString('hex') })
  }
}

const t1 = process.hrtime.bigint()
const finishedAt = new Date()
const elapsedMs = Number(t1 - t0) / 1e6

const result = {
  ...env,
  seed: SEED,
  steps: STEPS,
  checkpointEvery: CHECKPOINT_EVERY,
  startedAt: startedAt.toISOString(),
  finishedAt: finishedAt.toISOString(),
  elapsedMs: Math.round(elapsedMs * 10) / 10,
  stepsPerSecond: Math.round(STEPS / (elapsedMs / 1000)),
  resultHash: h.toString('hex'),
  checkpoints,
}

fs.mkdirSync(path.dirname(path.resolve(OUT)), { recursive: true })
fs.writeFileSync(OUT, JSON.stringify(result, null, 2), 'utf8')

// 同时打印一行摘要，便于 ssh 直接抓取
console.log(JSON.stringify({
  hostname: result.hostname,
  elapsedMs: result.elapsedMs,
  resultHash: result.resultHash,
  stepsPerSecond: result.stepsPerSecond,
  out: path.resolve(OUT),
}))
