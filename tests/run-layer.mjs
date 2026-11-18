#!/usr/bin/env node
// 分层测试 runner（适配器，不重写任何既有用例）
//
//   node tests/run-layer.mjs unit                 纯逻辑，秒级
//   node tests/run-layer.mjs integration          浏览器 + mock 上游，分钟级
//   node tests/run-layer.mjs e2e                  真上游 + 真 UI（需 E2E_API_KEY）
//   node tests/run-layer.mjs device               模拟器/真机（需 adb + 已启动的 AVD）
//   node tests/run-layer.mjs all                  依次跑 unit → integration
//
// 可选参数：
//   --only <子串>   只跑文件名包含该子串的用例（例：--only motion）
//   --bail          第一个失败就停
//   --list          只列出将执行的用例，不执行
//
// 为什么不直接 import()：仓库里的用例都是「自执行 + process.exit()」风格的历史脚本
// （自建 assert + 打印 ok/✗）。同进程 import() 会被第一个 process.exit() 直接带走，
// 所以这里统一用子进程执行、退出码判定，既不动用例也能汇总 PASS/FAIL。
// 用例若改用 node:test（import 'node:test'），runner 会自动改用 `node --test <file>` 执行。
//
// 所有用例的 cwd 都是仓库根目录（与历史跑法一致），因此测试内的相对路径（dist/、docs/ui/）不变。
import { spawn } from 'node:child_process'
import { readdir, readFile } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const TESTS_DIR = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(TESTS_DIR, '..')

const LAYERS = {
  unit: { dir: 'unit', hint: '纯逻辑、零浏览器、毫秒级' },
  integration: { dir: 'integration', hint: '浏览器 + mock 上游、分钟级' },
  e2e: { dir: 'e2e', hint: '真上游 + 真 UI，需要 E2E_API_KEY' },
  device: { dir: 'device', hint: '模拟器/真机，需要 adb + AVD' },
}

const argv = process.argv.slice(2)
const flags = new Set(argv.filter((a) => a.startsWith('--') && a !== '--only'))
const onlyIndex = argv.indexOf('--only')
const only = onlyIndex >= 0 ? argv[onlyIndex + 1] : ''
const layerArg = argv.find((a) => !a.startsWith('--') && a !== only) || ''

const plan = layerArg === 'all' ? ['unit', 'integration'] : layerArg ? [layerArg] : []
if (plan.length === 0 || plan.some((layer) => !LAYERS[layer])) {
  console.error('用法：node tests/run-layer.mjs <unit|integration|e2e|device|all> [--only <子串>] [--bail] [--list]')
  console.error(`可用层：${Object.keys(LAYERS).join(', ')}, all`)
  process.exit(2)
}

/** 该层要跑的文件（按文件名排序，保证输出稳定） */
const filesOf = async (layer) => {
  const dir = path.join(TESTS_DIR, LAYERS[layer].dir)
  let names = []
  try {
    names = (await readdir(dir)).filter((name) => name.endsWith('.test.mjs'))
  } catch {
    return []
  }
  return names
    .filter((name) => (only ? name.includes(only) : true))
    .sort()
    .map((name) => path.join(dir, name))
}

const rel = (file) => path.relative(ROOT, file).split(path.sep).join('/')

// 自己起静态服务的用例（它们自己 build/serve 那一份产物）：这些用例绝不能被外部的
// APP_URL 覆盖，否则「整层一起跑」时会去打标准构建而全部失败。清空 APP_URL 让它们
// 回落到自己的 default（127.0.0.1:<自己的端口>）。
const SELF_SERVED = new Set([
  'internal-build.test.mjs',
  'motion.test.mjs',
  'mode-switch.test.mjs',
  'diagnostics.test.mjs',
  'diagnostics-contract.test.mjs',
  'auto-title.test.mjs',
  'feedback-export.test.mjs',
  'mode-switch-plain.test.mjs',
  'provider-channels.test.mjs',
])

/** 用例的环境守卫退出码：77 = 端口被占/产物种类不对/产物陈旧（SKIP，不算失败） */
const SKIP_CODE = 77

/** 集成层基线清单（只判「不新增失败」） */
const BASELINE_FILE = path.join(TESTS_DIR, 'integration-baseline.json')

/** 用 node:test 写的用例走 `node --test`，历史自执行脚本直接 `node <file>` */
const usesNodeTest = async (file) =>
  /from\s+['"]node:test['"]|require\(['"]node:test['"]\)/.test(await readFile(file, 'utf8'))

const runFile = async (file) =>
  new Promise((resolve) => {
    const nodeTest = usesNodeTestCache.get(file)
    const args = nodeTest ? ['--test', file] : [file]
    const startedAt = Date.now()
    const env = { ...process.env }
    if (SELF_SERVED.has(path.basename(file))) env.APP_URL = ''
    const child = spawn(process.execPath, args, {
      cwd: ROOT,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const tail = []
    const keep = (chunk) => {
      tail.push(chunk.toString())
      if (tail.length > 400) tail.splice(0, tail.length - 400)
    }
    child.stdout.on('data', (chunk) => {
      process.stdout.write(chunk)
      keep(chunk)
    })
    child.stderr.on('data', (chunk) => {
      process.stderr.write(chunk)
      keep(chunk)
    })
    child.on('error', (error) => {
      resolve({ ok: false, ms: Date.now() - startedAt, tail: [String(error)] })
    })
    child.on('close', (code, signal) => {
      const text = tail.join('')
      const skipped = code === SKIP_CODE
      const reason = skipped ? (/SKIP\(env\) (.+)/.exec(text)?.[1] ?? '环境不满足').trim() : ''
      resolve({ ok: code === 0 && !signal, skipped, reason, ms: Date.now() - startedAt, tail })
    })
  })

const usesNodeTestCache = new Map()

const main = async () => {
  const all = []
  for (const layer of plan) {
    const files = await filesOf(layer)
    all.push({ layer, files })
  }

  const total = all.reduce((sum, { files }) => sum + files.length, 0)
  if (total === 0) {
    console.error(`没有匹配的用例（layer=${plan.join('/')}${only ? `, only=${only}` : ''}）`)
    process.exit(1)
  }

  if (flags.has('--list')) {
    for (const { layer, files } of all) {
      console.log(`[${layer}] ${LAYERS[layer].hint}`)
      for (const file of files) console.log(`  ${rel(file)}`)
    }
    return 0
  }

  for (const { files } of all) {
    for (const file of files) usesNodeTestCache.set(file, await usesNodeTest(file))
  }

  const results = []
  for (const { layer, files } of all) {
    console.log(`\n${'='.repeat(70)}\n== 层：${layer}（${LAYERS[layer].hint}，${files.length} 个文件）\n${'='.repeat(70)}`)
    for (const file of files) {
      console.log(`\n${'-'.repeat(70)}\n>> ${rel(file)}\n${'-'.repeat(70)}`)
      const result = await runFile(file)
      results.push({ layer, file, ...result })
      const status = result.ok ? 'PASS' : result.skipped ? 'SKIP(env)' : 'FAIL'
      console.log(`<< ${status} ${rel(file)}（${(result.ms / 1000).toFixed(1)}s）`)
      if (result.skipped) {
        console.log(`   ↳ ${result.reason}`)
      }
      if (!result.ok && flags.has('--bail')) {
        console.log('\n（--bail：遇到失败即停止）')
        return summarize(results)
      }
    }
  }
  return summarize(results)

  function summarize(list) {
    const failed = list.filter((r) => !r.ok && !r.skipped)
    const skipped = list.filter((r) => r.skipped)
    console.log(`\n${'='.repeat(70)}\n== 汇总\n${'='.repeat(70)}`)
    let current = ''
    for (const r of list) {
      if (r.layer !== current) {
        current = r.layer
        console.log(`[${current}]`)
      }
      const status = r.ok ? 'PASS' : r.skipped ? 'SKIP(env)' : 'FAIL'
      console.log(`  ${status}  ${rel(r.file)}  ${(r.ms / 1000).toFixed(1)}s`)
      if (r.skipped) {
        console.log(`        ↳ ${r.reason}`)
      }
    }
    const ms = list.reduce((sum, r) => sum + r.ms, 0)
    const passed = list.filter((r) => r.ok).length
    console.log(
      `\n共 ${list.length} 个文件：通过 ${passed}，失败 ${failed.length}，跳过(环境) ${skipped.length}（总耗时 ${(ms / 1000).toFixed(1)}s）`
    )
    if (failed.length > 0) {
      console.log('失败用例：')
      for (const r of failed) console.log(`  - ${rel(r.file)}`)
    }
    if (skipped.length > 0) {
      console.log('跳过（环境不满足，不产生假红）：')
      for (const r of skipped) console.log(`  - ${rel(r.file)}：${r.reason}`)
    }
    const verdict = compareWithBaseline(list)
    if (verdict !== null) {
      return verdict
    }
    if (failed.length > 0) {
      return 1
    }
    console.log('全部通过 ✅')
    return 0
  }

  /** --baseline：与 tests/integration-baseline.json 比对，只判「不新增失败」 */
  function compareWithBaseline(list) {
    if (!flags.has('--baseline')) {
      return null
    }
    let baseline
    try {
      baseline = JSON.parse(readFileSync(BASELINE_FILE, 'utf8'))
    } catch (error) {
      console.error(`\n读数失败：${BASELINE_FILE}（${error.message}）——没有基线就按普通模式判定`)
      return null
    }
    const expectedOf = (file) => baseline.files?.[path.basename(file)] ?? null
    const newFails = []
    const fixed = []
    const knownRed = []
    const skipped = []
    for (const r of list) {
      const entry = expectedOf(r.file)
      const expected = entry?.expected ?? 'pass'
      if (r.skipped) {
        skipped.push({ file: rel(r.file), reason: r.reason })
        continue
      }
      if (r.ok && expected === 'known-red') {
        fixed.push(rel(r.file))
      } else if (!r.ok && expected === 'known-red') {
        knownRed.push(rel(r.file))
      } else if (!r.ok) {
        newFails.push({ file: rel(r.file), reason: entry?.reason ?? '' })
      }
    }
    console.log(`\n${'='.repeat(70)}\n== 基线比对（${path.basename(BASELINE_FILE)}，基线：${baseline.baseline?.ref ?? '未注明'}）\n${'='.repeat(70)}`)
    const total = list.length
    const failedCount = list.filter((r) => !r.ok && !r.skipped).length
    const expectedRedCount = Object.values(baseline.files ?? {}).filter((entry) => entry.expected === 'known-red').length
    console.log(`本次失败 ${failedCount} / 基线登记红 ${expectedRedCount} / 新增失败 ${newFails.length} / 已转绿 ${fixed.length} / 跳过(环境) ${skipped.length}（共 ${total} 个文件）`)
    if (knownRed.length > 0) {
      for (const file of knownRed) console.log(`  KNOWN-RED  ${file}（基线已登记，不算新增）`)
    }
    if (skipped.length > 0) {
      for (const item of skipped) console.log(`  SKIP(ENV)  ${item.file}：${item.reason}`)
    }
    if (fixed.length > 0) {
      console.log('基线里记着红、但这次通过了（请更新基线清单）：')
      for (const file of fixed) console.log(`  FIXED?     ${file}`)
    }
    if (newFails.length > 0) {
      console.log('新增失败（基线里期望通过）：')
      for (const item of newFails) console.log(`  NEW FAIL   ${item.file}${item.reason ? `（${item.reason}）` : ''}`)
    }
    if (newFails.length === 0 && fixed.length === 0) {
      console.log('\n相对基线没有新增失败 ✅')
      return 0
    }
    return 1
  }
}

process.exit(await main())
