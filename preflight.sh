#!/usr/bin/env bash
# =============================================================================
# preflight.sh —— 发布门禁：九项检查，任何一项 FAIL 就中止（非零退出码）
#
#   ./preflight.sh                     # 完整门禁
#   ./preflight.sh --skip-tests        # 跳过 4/5/6（测试类），打印醒目警告
#   ./preflight.sh --dry-run           # 只打印将执行什么，不真跑
#   ./preflight.sh --planned-version 1.5.0
#                                       # 发布前预演：第 7 项按「versionCode+1 / 新版本号」
#                                       # 评估（release-apk.sh 自动透传）
#
# 九项：
#   1 git 工作区干净   2 TypeScript 类型检查   3 lint（oxlint）   4 unit 测试
#   5 integration 测试（相对基线无新增失败）    6 e2e 真上游测试    7 版本号递增校验   8 CHANGELOG 段落
#   9 APK 元信息校验
#
# 环境变量：GRADLE / APK / AAPT2 / RELEASES_URL / CHANGELOG
#           UNIT_CMD / INTEGRATION_CMD / E2E_CMD（覆盖默认命令）
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}" || { printf 'ERROR: 进不去脚本目录 %s\n' "${ROOT_DIR}" >&2; exit 1; }

GRADLE=${GRADLE:-android/app/build.gradle}
APK=${APK:-android/app/build/outputs/apk/debug/app-debug.apk}
AAPT2=${AAPT2:-/root/android-sdk/build-tools/35.0.0/aapt2}
RELEASES_URL=${RELEASES_URL:-https://dl.rose7.cn/releases.json}
CHANGELOG=${CHANGELOG:-CHANGELOG.md}

SKIP_TESTS=0
DRY_RUN=0
PLANNED_VER=''
PLANNED_VC=''
ALLOW_SAME=0
SKIP_UPSTREAM=0          # 仅跳过“真实模型上游”e2e（4/5 与反馈上传 e2e 照跑）
E2E_UPSTREAM_MATCH=${E2E_UPSTREAM_MATCH:-real-upstream}   # 上游用例文件名匹配子串

usage() {
  cat <<'USAGE'
用法: ./preflight.sh [选项]

发布门禁：九项检查，任一 FAIL 即中止（退出码 1）。

  --skip-tests              跳过第 4/5/6 项（unit / integration / e2e），会打印醒目警告
  --dry-run                 只打印将执行什么，不真跑
  --planned-version <x.y.z> 发布预演：第 7 项按「versionName=<x.y.z>」评估
  --planned-versioncode <n> 配合 --planned-version：直接用 n 作为待发布 versionCode
  --skip-upstream-e2e       仅跳过第 6 项里【真实模型上游】e2e（需延后补测），
                            unit/integration/反馈上传 e2e 仍照跑；会留痕
  --allow-same-version      同版本续发：允许 planned versionCode == 远端 latest 且版本号相同
                            （release-apk.sh 发现同 artifact 续发时自动透传）
  -h, --help                显示本帮助

退出码：0 = 通过（允许 SKIP）；1 = 有 FAIL；2 = 参数错误
USAGE
}

while (( $# )); do
  case "$1" in
    --skip-tests) SKIP_TESTS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --planned-version) shift; PLANNED_VER=${1:-}; [[ -n ${PLANNED_VER} ]] || { usage >&2; printf 'ERROR: --planned-version 缺少参数\n' >&2; exit 2; } ;;
    --planned-version=*) PLANNED_VER=${1#*=} ;;
    --planned-versioncode) shift; PLANNED_VC=${1:-}; [[ ${PLANNED_VC} =~ ^[0-9]+$ ]] || { usage >&2; printf 'ERROR: --planned-versioncode 需要数字\n' >&2; exit 2; } ;;
    --planned-versioncode=*) PLANNED_VC=${1#*=} ;;
    --allow-same-version) ALLOW_SAME=1 ;;
    --skip-upstream-e2e) SKIP_UPSTREAM=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; printf 'ERROR: 未知参数 %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 小工具
if [[ -t 1 ]]; then
  C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'; C_YEL=$'\e[1;33m'; C_CYN=$'\e[1;36m'; C_OFF=$'\e[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_OFF=''
fi

now_ms() { date +%s%3N; }
LOG_DIR=$(mktemp -d /tmp/preflight.XXXXXX)
cleanup() { rm -rf "${LOG_DIR}"; }
trap cleanup EXIT

ITEMS_NAME=(); ITEMS_STATUS=(); ITEMS_MS=(); ITEMS_NOTE=(); ITEMS_FIX=()
CUR_NO=0; CUR_NAME=''; T_START=0; RUN_TAIL=''

item() { CUR_NO=$1; CUR_NAME=$2; T_START=$(now_ms); printf '\n%s[%s/9] %s%s\n' "${C_CYN}" "$1" "$2" "${C_OFF}"; }
plan() { printf '      · 将执行: %s\n' "$*"; }

verdict() {
  local st=$1 note=${2:-} fix=${3:-} ms
  ms=$(( $(now_ms) - T_START ))
  ITEMS_NAME+=("${CUR_NAME}"); ITEMS_STATUS+=("${st}"); ITEMS_MS+=("${ms}")
  ITEMS_NOTE+=("${note}"); ITEMS_FIX+=("${fix}")
  case ${st} in
    PASS)    printf '      %s✅ PASS%s  %sms  %s\n' "${C_GRN}" "${C_OFF}" "${ms}" "${note}" ;;
    FAIL)    printf '      %s❌ FAIL%s  %sms  %s\n' "${C_RED}" "${C_OFF}" "${ms}" "${note}"
             [[ -n ${fix} ]] && printf '      %s🔧 修复: %s%s\n' "${C_YEL}" "${fix}" "${C_OFF}" ;;
    SKIP)    printf '      %s⚠️  SKIP%s  %sms  %s\n' "${C_YEL}" "${C_OFF}" "${ms}" "${note}" ;;
    PLANNED) printf '      %s⏭️  DRY-RUN%s  未执行\n' "${C_CYN}" "${C_OFF}" ;;
  esac
  return 0
}

# run_logged <tag> <desc> -- cmd...  ：输出进日志，失败时把尾巴回显
run_logged() {
  local tag=$1 desc=$2; shift 2
  local log="${LOG_DIR}/${tag}.log"
  if "$@" >"${log}" 2>&1; then
    RUN_TAIL=$(tail -2 "${log}" 2>/dev/null || true); return 0
  fi
  RUN_TAIL=$(tail -20 "${log}" 2>/dev/null || true); return 1
}
show_tail() { [[ -n ${RUN_TAIL//[$' \t\n']/} ]] && printf '%s\n' "${RUN_TAIL}" | sed 's/^/        │ /'; return 0; }

has_script() {
  node -e 'const s=(require("./package.json").scripts)||{};process.exit(s[process.argv[1]]?0:1)' "$1" 2>/dev/null
}

gradle_versioncode() { sed -n 's/^[[:space:]]*versionCode[[:space:]]\+\([0-9]\+\).*/\1/p' "${GRADLE}" | head -1; }
gradle_versionname() { sed -n 's/^[[:space:]]*versionName[[:space:]]"\([^"]*\)".*/\1/p' "${GRADLE}" | head -1; }

# semver_gt A B → 打印 1/0（A > B）；无法解析时返回 3
semver_gt() {
  python3 - "$1" "$2" <<'PY'
import re,sys
def key(v):
    m=re.match(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$',v.strip())
    if not m: return None
    nums=tuple(int(m.group(i)) for i in (1,2,3))
    pre=m.group(4)
    return nums, (0,[]) if pre is None else (1,[t for t in pre.split('.')])
a,b=key(sys.argv[1]),key(sys.argv[2])
if a is None or b is None: print('3'); sys.exit(0)
def cmp(a,b):
    if a[0]!=b[0]: return 1 if a[0]>b[0] else -1
    # 正式版(0) > 预发布(1)
    if a[1][0]!=b[1][0]: return 1 if a[1][0]<b[1][0] else -1
    if a[1][0]==0: return 0
    for x,y in zip(a[1][1],b[1][1]):
        xd,yx=x.isdigit(),y.isdigit()
        if xd and yx:
            if int(x)!=int(y): return 1 if int(x)>int(y) else -1
        elif xd!=yx:
            return -1 if xd else 1
        elif x!=y:
            return 1 if x>y else -1
    if len(a[1][1])!=len(b[1][1]): return 1 if len(a[1][1])>len(b[1][1]) else -1
    return 0
print('1' if cmp(a,b)>0 else '0')
PY
}

printf '%s=== 发布门禁 preflight ===%s  仓库 %s\n' "${C_CYN}" "${C_OFF}" "${ROOT_DIR}"
printf '版本来源 %s   changelog %s   远端 %s\n' "${GRADLE}" "${CHANGELOG}" "${RELEASES_URL}"
if (( SKIP_TESTS )); then
  printf '\n%s' "${C_YEL}"
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
  printf '!!  警告：--skip-tests 已启用，单元 / 集成 / e2e 三类测试全部跳过！    !!\n'
  printf '!!  这次发布没有经过测试验证，只保证类型、lint、版本号、CHANGELOG。   !!\n'
  printf '!!  留痕要求：CHANGELOG 版本标题会带 " [未过门禁]"，Release notes 也   !!\n'
  printf '!!  会注明；请在发布说明里写清跳过原因。                              !!\n'
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
  printf '%s' "${C_OFF}"
fi
if (( SKIP_UPSTREAM )); then
  printf '\n%s' "${C_YEL}"
  printf '%s\n' '----------------------------------------------------------------------'
  printf '!!  --skip-upstream-e2e：只跳过【真实模型上游】e2e（发布后补测）       !!\n'
  printf '!!  unit / integration / 反馈上传 e2e 仍然照跑；CHANGELOG 与 Release  !!\n'
  printf '!!  notes 会写明“真实模型上游测试待发布后补测”。                      !!\n'
  printf '%s\n' '----------------------------------------------------------------------'
  printf '%s' "${C_OFF}"
fi
if (( DRY_RUN )); then
  printf '\n%s[dry-run] 只打印计划，不执行任何检查、不改任何文件%s\n' "${C_CYN}" "${C_OFF}"
fi
[[ -n ${PLANNED_VER} ]] && printf '预演版本 %s（第 7 项按 versionName=%s / versionCode=%s 评估%s）\n' \
  "${PLANNED_VER}" "${PLANNED_VER}" "${PLANNED_VC:-<本地+1>}" "$([[ ${ALLOW_SAME} == 1 ]] && echo '，允许同版本续发')"


# ---------------------------------------------------------------- 1) git 干净
item 1 "git 工作区干净"
if (( DRY_RUN )); then
  plan "git status --porcelain（要求为空）"
  verdict PLANNED
else
  DIRTY=$(git status --porcelain 2>/dev/null || true)
  if [[ -z ${DIRTY} ]]; then
    verdict PASS "git status --porcelain 为空"
  else
    printf '%s\n' "${DIRTY}" | head -12 | sed 's/^/        │ /'
    N=$(printf '%s\n' "${DIRTY}" | wc -l)
    verdict FAIL "工作区有 ${N} 个未提交改动" "先 git commit -m '...' 或 git stash；注意本仓库可能有其它 agent 在改 package.json / tests/，不要用 git add -A"
  fi
fi

# ---------------------------------------------------------------- 2) 类型检查
item 2 "TypeScript 类型检查"
if (( DRY_RUN )); then
  if has_script type; then plan "pnpm type  (tsc -p tsconfig.json)"; else plan "npx tsc -p tsconfig.json  （package.json 无 type 脚本）"; fi
  verdict PLANNED
else
  if has_script type; then
    DESC='pnpm type'; CMD=(pnpm type)
  else
    DESC='npx tsc -p tsconfig.json（package.json 无 type 脚本，已降级）'; CMD=(npx tsc -p tsconfig.json)
  fi
  if run_logged type "${DESC}" "${CMD[@]}"; then
    verdict PASS "${DESC}"
  else
    show_tail
    verdict FAIL "${DESC} 报错" "按上面的 tsc 报错修类型；本脚本只拦截不改代码（别在这里改 package.json）"
  fi
fi

# ---------------------------------------------------------------- 3) lint
item 3 "lint（oxlint）"
if (( DRY_RUN )); then
  if has_script lint; then plan "pnpm lint  (oxlint src rspack.config.ts)"; else plan "npx oxlint src rspack.config.ts"; fi
  verdict PLANNED
else
  if has_script lint; then
    DESC='pnpm lint'; CMD=(pnpm lint)
  else
    DESC='npx oxlint src rspack.config.ts（package.json 无 lint 脚本，已降级）'; CMD=(npx oxlint src rspack.config.ts)
  fi
  if run_logged lint "${DESC}" "${CMD[@]}"; then
    verdict PASS "${DESC}"
  else
    show_tail
    verdict FAIL "${DESC} 有告警/错误" "修 lint 问题，或 npx oxlint --fix <file>；不要改 .oxlintrc.json 来放水"
  fi
fi

# ---------------------------------------------------------------- 4) unit
item 4 "unit 测试"
if (( SKIP_TESTS )); then
  verdict SKIP "被 --skip-tests 跳过（未验证）"
elif (( DRY_RUN )); then
  if [[ -n ${UNIT_CMD:-} ]]; then plan "${UNIT_CMD}"; elif has_script test; then plan "npm run test"
  elif [[ -d tests/unit ]]; then plan "node --test tests/unit"; else plan "（无 unit 测试目标 → 会标记 SKIP）"; fi
  verdict PLANNED
else
  if [[ -n ${UNIT_CMD:-} ]]; then
    if bash -c "${UNIT_CMD}" >"${LOG_DIR}/unit.log" 2>&1; then RUN_TAIL=$(tail -2 "${LOG_DIR}/unit.log"); verdict PASS "UNIT_CMD: ${UNIT_CMD}"
    else RUN_TAIL=$(tail -20 "${LOG_DIR}/unit.log"); show_tail; verdict FAIL "UNIT_CMD 失败: ${UNIT_CMD}" "复跑看完整输出：${UNIT_CMD}"; fi
  elif has_script test; then
    if run_logged unit 'npm run test' npm run test; then verdict PASS 'npm run test'; else show_tail; verdict FAIL 'npm run test 失败' '复跑：npm run test（只调试失败的那个 spec）'; fi
  elif [[ -d tests/unit ]]; then
    if run_logged unit 'node --test tests/unit' node --test tests/unit; then verdict PASS 'node --test tests/unit（降级）'; else show_tail; verdict FAIL 'node --test tests/unit 失败' '复跑：node --test tests/unit'; fi
  else
    UNIT_FILES=$(ls tests/test.*.spec.mjs 2>/dev/null | wc -l)
    verdict SKIP "无 unit 目标：package.json 无 test 脚本、tests/unit 不存在（tests/ 下另有 ${UNIT_FILES} 个 *.spec.mjs，未被 unit 门禁覆盖）"
  fi
fi

# ---------------------------------------------------------------- 5) integration
# 判定口径：**相对基线没有新增失败**（tests/integration-baseline.json），不是「全绿」。
# 基线里登记为 known-red 的用例照常执行但不判失败；环境不满足的用例由用例自己 SKIP(env)。
item 5 "integration 测试（相对基线无新增失败）"
if (( SKIP_TESTS )); then
  verdict SKIP "被 --skip-tests 跳过（未验证）"
elif (( DRY_RUN )); then
  if [[ -n ${INTEGRATION_CMD:-} ]]; then plan "${INTEGRATION_CMD}"; elif has_script test:integration:baseline; then plan "APP_URL=<标准包地址> npm run test:integration:baseline"
  elif has_script test:integration; then plan "npm run test:integration（无基线脚本，按全绿判定）"
  elif [[ -d tests/integration ]]; then plan "node --test tests/integration"; else plan "（无 integration 目标 → 会标记 SKIP）"; fi
  verdict PLANNED
else
  if [[ -n ${INTEGRATION_CMD:-} ]]; then
    if bash -c "${INTEGRATION_CMD}" >"${LOG_DIR}/integration.log" 2>&1; then RUN_TAIL=$(tail -2 "${LOG_DIR}/integration.log"); verdict PASS "INTEGRATION_CMD: ${INTEGRATION_CMD}"
    else RUN_TAIL=$(tail -20 "${LOG_DIR}/integration.log"); show_tail; verdict FAIL "INTEGRATION_CMD 失败: ${INTEGRATION_CMD}" "复跑看完整输出：${INTEGRATION_CMD}"; fi
  elif has_script test:integration:baseline; then
    if run_logged integration 'npm run test:integration:baseline' npm run test:integration:baseline; then
      RUN_TAIL=$(grep -E '本次失败|新增失败' "${LOG_DIR}/integration.log" | tail -1)
      verdict PASS "npm run test:integration:baseline（${RUN_TAIL:-相对基线无新增失败}）"
    else
      show_tail
      verdict FAIL 'integration 相对基线出现新增失败' '复跑：npm run test:integration:baseline（明细见 tests/integration-baseline.json 与 docs/testing.md）'
    fi
  elif has_script test:integration; then
    if run_logged integration 'npm run test:integration' npm run test:integration; then verdict PASS 'npm run test:integration'
    else show_tail; verdict FAIL 'npm run test:integration 失败' '复跑：npm run test:integration'; fi
  elif [[ -d tests/integration ]]; then
    if run_logged integration 'node --test tests/integration' node --test tests/integration; then verdict PASS 'node --test tests/integration（降级）'
    else show_tail; verdict FAIL 'node --test tests/integration 失败' '复跑：node --test tests/integration'; fi
  else
    verdict SKIP '无 integration 目标：package.json 无 test:integration 脚本、tests/integration 不存在'
  fi
fi

# ---------------------------------------------------------------- 6) e2e
item 6 "e2e（反馈上传必跑 + 真上游模型）"
E2E_DIR=${E2E_DIR:-tests/e2e}
e2e_runner(){  # <--only 参数>  → 跑分层 runner 的 e2e 层
  if [[ -n ${E2E_CMD:-} ]]; then bash -c "${E2E_CMD}"; return $?; fi
  if has_script test:e2e; then node tests/run-layer.mjs e2e "$@"; return $?; fi
  return 127
}
if (( SKIP_TESTS )); then
  verdict SKIP "被 --skip-tests 全量跳过（未验证；正常发版不要用它，改用 --skip-upstream-e2e）"
elif (( DRY_RUN )); then
  plan "反馈上传/其它 e2e（必须跑并必须过）：遍历 ${E2E_DIR}/*.test.mjs，排除 *${E2E_UPSTREAM_MATCH}*，逐个 node tests/run-layer.mjs e2e --only <用例>"
  if (( SKIP_UPSTREAM )); then plan "真实模型上游 e2e：SKIP（--skip-upstream-e2e → 发布后补测，会留痕）"
  elif [[ -z ${E2E_API_KEY:-} ]]; then plan "真实模型上游 e2e：缺 E2E_API_KEY → FAIL（或用 --skip-upstream-e2e 明确延后补测）"
  else plan "真实模型上游 e2e：node tests/run-layer.mjs e2e --only ${E2E_UPSTREAM_MATCH}"; fi
  verdict PLANNED
else
  UPLOAD_OK=1; RAN_UPLOAD=''; FAILED_CASE=''
  if [[ ! -d ${E2E_DIR} ]]; then
    verdict FAIL "找不到 e2e 目录 ${E2E_DIR}：反馈上传 e2e 无法运行（缺证据）" "确认 tests/e2e/ 存在，或用 E2E_DIR 指到正确目录"
  else
    for f in ${E2E_DIR}/*.test.mjs; do
      [[ -e ${f} ]] || continue
      bn=$(basename "${f}" .test.mjs)
      case ${bn} in *"${E2E_UPSTREAM_MATCH}"*) continue;; esac
      RAN_UPLOAD="${RAN_UPLOAD} ${bn}"
      if ! run_logged "e2e_${bn//[^A-Za-z0-9_.-]/_}" "e2e --only ${bn}" bash -c "node tests/run-layer.mjs e2e --only '${bn}'"; then
        UPLOAD_OK=0; FAILED_CASE=${bn}; break
      fi
    done
    if (( UPLOAD_OK == 0 )); then
      show_tail
      verdict FAIL "e2e 用例 ${FAILED_CASE} 失败（反馈上传类 e2e 是必跑项）" "复跑：node tests/run-layer.mjs e2e --only ${FAILED_CASE}"
    elif (( SKIP_UPSTREAM )); then
      verdict SKIP "反馈上传等 e2e 已通过（${RAN_UPLOAD# }）；真实模型上游 e2e 按 --skip-upstream-e2e 跳过 → **待发布后补测**（写进 CHANGELOG/Release notes）"
    elif [[ -z ${E2E_API_KEY:-} ]]; then
      verdict FAIL "缺 E2E_API_KEY：真实模型上游 e2e 无证据（反馈上传 e2e ${RAN_UPLOAD# } 已通过）" \
        'export E2E_API_KEY=sk-xxx 后重跑；若明确接受“发布后补测”，用 --skip-upstream-e2e（会留痕），不要用 --skip-tests'
    elif ! ls ${E2E_DIR}/*"${E2E_UPSTREAM_MATCH}"*.test.mjs >/dev/null 2>&1; then
      verdict FAIL "找不到真实模型上游用例（${E2E_DIR}/*${E2E_UPSTREAM_MATCH}*.test.mjs）" \
        '确认用例仍在 tests/e2e/ 下；run-layer 的 --only 匹配不到时会静默 exit 0，这里必须显式拦截'
    else
      if run_logged e2e_upstream "e2e --only ${E2E_UPSTREAM_MATCH}" bash -c "node tests/run-layer.mjs e2e --only '${E2E_UPSTREAM_MATCH}'"; then
        verdict PASS "上传类 e2e（${RAN_UPLOAD# }）+ 真实模型上游 e2e 全部通过"
      else
        show_tail
        verdict FAIL "真实模型上游 e2e 失败" '三步定位：1) curl $E2E_UPSTREAM_URL/v1/models 2) SSE 是否 flush 3) 前端解析；确属上游不可用再考虑 --skip-upstream-e2e（留痕）'
      fi
    fi
  fi
fi
# ---------------------------------------------------------------- 7) 版本号递增
item 7 "版本号递增校验"
LVC=$(gradle_versioncode); LVN=$(gradle_versionname)
if [[ -z ${LVC} || -z ${LVN} ]]; then
  verdict FAIL "读不到 build.gradle 的 versionCode/versionName（${GRADLE}）" "确认文件存在且行格式为 'versionCode N' / 'versionName \"x.y.z\"'"
elif (( DRY_RUN )); then
  plan "读 ${GRADLE}（versionCode=${LVC}, versionName=${LVN}）→ curl -fsS ${RELEASES_URL} → 要求待发布 versionCode(${PLANNED_VC:-$((LVC+1))}) > latest.versionCode（网络不通则降级比 CHANGELOG 最新版本）"
  verdict PLANNED
else
  T_VC=${LVC}; T_VN=${LVN}; PRE_NOTE=''
  if [[ -n ${PLANNED_VER} ]]; then
    T_VN=${PLANNED_VER}
    if [[ -n ${PLANNED_VC} ]]; then T_VC=${PLANNED_VC}; else T_VC=$(( LVC + 1 )); fi
    PRE_NOTE="（预演口径：versionCode ${LVC}→${T_VC}, versionName ${LVN}→${T_VN}）"
  fi
  RJSON=''
  if [[ ${RELEASES_URL} != https://* ]]; then
    verdict FAIL "RELEASES_URL 必须是 https:// 开头（当前 ${RELEASES_URL}）" '改成 https 地址，防止被劫持/中间人'
  else
    RJSON=$(curl -fsS --max-time 15 "${RELEASES_URL}" 2>"${LOG_DIR}/curl.err" || true)
  fi
  RVC=''; RV=''
  if [[ -n ${RJSON} ]]; then
    read -r RVC RV <<<"$(printf '%s' "${RJSON}" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("0 -"); raise SystemExit
rel=d.get("releases") or []
latest=str(d.get("latest") or "")
vc=0; v=latest
for r in rel:
    if str(r.get("version") or "")==latest:
        vc=int(r.get("versionCode") or 0); v=r.get("version") or latest; break
if vc==0 and rel:
    b=max(rel,key=lambda x:int(x.get("versionCode") or 0)); vc=int(b.get("versionCode") or 0); v=str(b.get("version") or "")
print(vc,v)
' 2>/dev/null || echo '0 -')"
  fi
  if [[ -n ${RVC} && ${RVC} != 0 ]]; then
    if (( T_VC > RVC )); then
      verdict PASS "远端 latest=v${RV} versionCode=${RVC} < 待发布 ${T_VC} ${PRE_NOTE}"
    elif (( ALLOW_SAME )) && (( T_VC == RVC )) && [[ ${T_VN} == "${RV}" ]]; then
      verdict PASS "同版本续发：${T_VN} 的 versionCode ${T_VC} 已等于远端 latest（服务端允许同版本重传，不重复递增）"
    else
      verdict FAIL "远端已发布 versionCode=${RVC}（v${RV}），待发布只有 ${T_VC}，没有递增" "把 ${GRADLE} 的 versionCode 提到 $(( RVC + 1 )) 以上（release-apk.sh 会按 max(本地,远端)+1 自动设定）"
    fi
  else
    # 网络不通 → 降级为与 CHANGELOG 最新版本比较
    CL_VER=$(sed -n 's/^##[[:space:]]\{1,\}\([0-9][0-9A-Za-z._-]*\).*/\1/p' "${CHANGELOG}" 2>/dev/null | head -1)
    if [[ -z ${CL_VER} ]]; then
      verdict FAIL "拉不到 ${RELEASES_URL}（$(tail -1 "${LOG_DIR}/curl.err" 2>/dev/null)），CHANGELOG 也读不到版本号" "检查网络/DNS；或确认 CHANGELOG.md 首条形如 '## 1.5.0 (日期) — 标题'"
    else
      GT=$(semver_gt "${T_VN}" "${CL_VER}")
      if [[ ${GT} == 1 ]]; then
        verdict PASS "网络不可用 → 降级比较：${T_VN} > CHANGELOG 最新 ${CL_VER} ${PRE_NOTE}"
      else
        verdict FAIL "网络不可用 → 降级比较：${T_VN} 未超过 CHANGELOG 最新 ${CL_VER}" "先确认版本号大于 ${CL_VER}（release-apk.sh 会自动把 versionName 设成新版本号）"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- 8) CHANGELOG
item 8 "CHANGELOG 段落在"
if (( DRY_RUN )); then
  plan "grep -E '^##[[:space:]]+${LVN:-<versionName>}' ${CHANGELOG}"
  verdict PLANNED
else
  ESC=${LVN//./\\.}
  if [[ -z ${LVN} ]]; then
    verdict FAIL "读不到 versionName" "先修 build.gradle"
  elif grep -qE "^##[[:space:]]+${ESC}([[:space:](]|$)" "${CHANGELOG}" 2>/dev/null; then
    verdict PASS "${CHANGELOG} 有 '## ${LVN}' 段落"
  else
    verdict FAIL "${CHANGELOG} 缺 '## ${LVN}' 段落（Release notes 会退化成只有 changes 列表）" "在 CHANGELOG.md 加 '## ${LVN} (日期) — 标题' 段；用 ./release-apk.sh 发版时第 4 步会自动写"
  fi
fi

# ---------------------------------------------------------------- 9) APK 元信息
item 9 "APK 元信息校验"
if (( DRY_RUN )); then
  plan "若 ${APK} 存在 → ${AAPT2} dump badging 比对 versionName/versionCode 与 ${GRADLE}"
  verdict PLANNED
elif [[ ! -f ${APK} ]]; then
  verdict SKIP "APK 还不存在（未构建）：${APK}"
elif [[ ! -x ${AAPT2} ]]; then
  verdict FAIL "aapt2 不可执行：${AAPT2}" "检查 Android SDK build-tools 是否安装，或 export AAPT2=<路径>"
else
  BADGING=$("${AAPT2}" dump badging "${APK}" 2>/dev/null || true)
  AVC=$(printf '%s\n' "${BADGING}" | sed -n "s/^package:.* versionCode='\([0-9]*\)'.*/\1/p" | head -1)
  AVN=$(printf '%s\n' "${BADGING}" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p" | head -1)
  if [[ -z ${AVC} ]]; then
    verdict SKIP "aapt2 读不到现有 APK 的 versionCode（APK 旧/损坏）——构建前不阻断，构建后由 release-apk 强校验"
  elif [[ ${AVC} == "${LVC}" && ${AVN} == "${LVN}" ]]; then
    verdict PASS "现有 APK=${AVN}(${AVC}) 与 gradle=${LVN}(${LVC}) 一致"
  else
    verdict SKIP "现有 APK=${AVN:-?}(${AVC}) 是旧版本（gradle=${LVN}(${LVC})）：构建前**不阻断**，构建后必须重新校验"
  fi
fi

# ---------------------------------------------------------------- 汇总
NP=0; NF=0; NS=0; NPL=0
printf '\n%s===== 门禁汇总 =====%s\n' "${C_CYN}" "${C_OFF}"
printf '%-3s %-22s %-9s %-8s %s\n' '#' '检查项' '结果' '耗时' '说明'
i=0
while (( i < ${#ITEMS_NAME[@]} )); do
  st=${ITEMS_STATUS[$i]}
  case ${st} in PASS) NP=$((NP+1));; FAIL) NF=$((NF+1));; SKIP) NS=$((NS+1));; PLANNED) NPL=$((NPL+1));; esac
  printf '%-3s %-22s %-9s %-8s %s\n' "$((i+1))" "${ITEMS_NAME[$i]}" "${st}" "$((ITEMS_MS[$i]))ms" "${ITEMS_NOTE[$i]}"
  i=$((i+1))
done
printf '\n通过 %d / 失败 %d / 跳过 %d / 未执行 %d\n' "${NP}" "${NF}" "${NS}" "${NPL}"

if (( NF > 0 )); then
  printf '\n%s❌ 门禁未通过：%d 项失败，发布中止%s\n' "${C_RED}" "${NF}" "${C_OFF}"
  i=0
  while (( i < ${#ITEMS_NAME[@]} )); do
    if [[ ${ITEMS_STATUS[$i]} == FAIL ]]; then
      printf '  %s. %s → %s\n' "$((i+1))" "${ITEMS_NAME[$i]}" "${ITEMS_FIX[$i]}"
    fi
    i=$((i+1))
  done
  exit 1
fi
if (( DRY_RUN )); then
  printf '\n%s✅ dry-run 结束：上面就是完整九项计划（没有任何检查被真正执行）%s\n' "${C_CYN}" "${C_OFF}"
elif (( SKIP_TESTS )); then
  printf '\n%s⚠️  通过（但 --skip-tests 生效：4/5/6 未验证，CHANGELOG 会标 [未过门禁]）%s\n' "${C_YEL}" "${C_OFF}"
elif (( SKIP_UPSTREAM )); then
  printf '\n%s✅ 门禁通过（真实模型上游 e2e 延后补测，其余含反馈上传 e2e 已跑）%s\n' "${C_YEL}" "${C_OFF}"
elif (( NS > 0 )); then
  printf '\n✅ 门禁通过（%d 项 SKIP：见上表，通常是测试目标缺失或旧 APK 待重建）\n' "${NS}"
else
  printf '\n%s✅ 门禁全部通过%s\n' "${C_GRN}" "${C_OFF}"
fi
exit 0
