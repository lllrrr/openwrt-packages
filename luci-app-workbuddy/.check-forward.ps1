# 扫描 ucode 前向引用与重复定义
# 用法: pwsh -File check-forward.ps1 <file>
param([string]$File = 'D:\AI\luci-app-workbuddy\files\usr\share\ucode\workbuddy.uc')

$lines = [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)

# 1) 顶层函数定义
$defs = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') {
        $n = $Matches[1]
        if ($defs.ContainsKey($n)) {
            Write-Host "  [DUP] $n  行$($defs[$n]) 与 行$($i+1)"
        } else { $defs[$n] = $i + 1 }
    }
}

# 2) 标记模板字符串区间（正确处理一行多个反引号）
$inTpl = $false
$tpl = New-Object bool[] $lines.Count
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $ticks = ([regex]::Matches($line, '`')).Count
    if ($inTpl) {
        $tpl[$i] = $true
        if ($ticks % 2 -eq 1) { $inTpl = $false }
    } else {
        if ($ticks % 2 -eq 1) { $tpl[$i] = $true; $inTpl = $true }
    }
}

# 3) 计算每个顶层函数的结束行
#
# 规则：函数体结束于**下一个顶格且非空非注释的行**之前。
#
# 为什么不能拿"下一个顶层函数的开始行"当结尾：顶层函数之间夹着 `let x = ...` /
# `const Y = ...` 这类顶层声明，用后者会把那些声明行算进上一个函数的函数体里，
# 于是"函数引用了自己后面才声明的全局"这类误报会成片出现
# （GLOBAL DECLARATION ORDER CHECK 第一版就是这么刷出 138 条假 RISK 的，
# 连 `loadUpstreams() 行1350 引用 upState，而它行1350 才声明` 这种"声明行自指"都报了出来）。
#
# 为什么也不能"找到下一个独占一行的 `}` 就收"：本文件里有单行函数
# （`function logInfo(m) { ... }`），它后面根本没有顶格 `}`，
# 那样扫描会一路吞到几十行之后的第一个顶格 `}`，把一整片顶层声明算进函数体里。
# 顶格规则对两种情况都对：单行函数的下一行就顶格，多行函数的闭合 `}` 也顶格。
$endOf = @{}
foreach ($n in $defs.Keys) {
    $s = $defs[$n] - 1
    $close = $lines.Count
    for ($j = $s + 1; $j -lt $lines.Count; $j++) {
        if ($tpl[$j]) { continue }
        $t = $lines[$j]
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match '^\s*//') { continue }
        if ($t -match '^\S') { $close = $j; break }
    }
    $endOf[$n] = $close + 1   # 一过末行（1-based），与下面 `$endOf - 1` 的约定配套
}

# 4) 找出前向引用
Write-Host ""
Write-Host "=== FORWARD REF CHECK ==="
$risk = 0
foreach ($n in $defs.Keys) {
    $s = $defs[$n] - 1
    $e = $endOf[$n] - 1
    for ($i = $s; $i -lt $e; $i++) {
        if ($tpl[$i]) { continue }
        $line = $lines[$i]
        if ($line -match '^\s*//') { continue }
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9_.$])([a-z_][A-Za-z0-9_]*)\s*\(')) {
            $callee = $m.Groups[1].Value
            if ($defs.ContainsKey($callee) -and $defs[$callee] -gt $defs[$n]) {
                if ($line -notmatch "F\.$callee\s*\(") {
                    Write-Host ("  [RISK] {0}(行{1}) 调用 {2}(行{3})" -f $n, $defs[$n], $callee, $defs[$callee])
                    $risk++
                }
            }
        }
    }
}

Write-Host ""
if ($risk -eq 0) { Write-Host "OK: no forward reference" } else { Write-Host "FAIL: $risk forward references" }
Write-Host "total top-level functions: $($defs.Count)"

# 5) ucode 不存在的内建方法调用
#
# ucode 的字符串、数组、对象都没有方法：s.replace() / a.push() / o.has()
# 都会在运行期抛 "left-hand side is not a function"。
# 这些错误只在被调到的那一行才暴露，静态扫一遍能提前拦住。
# 注意：模板字符串里的 JS 是给浏览器执行的，必须跳过。
Write-Host ""
Write-Host "=== METHOD CALL CHECK ==="
$badMethods = @('push', 'replace', 'includes', 'indexOf', 'slice', 'splice',
    'concat', 'filter', 'map', 'forEach', 'trim', 'split', 'join',
    'toLowerCase', 'toUpperCase', 'startsWith', 'endsWith', 'has',
    'substring', 'charAt', 'toString', 'repeat', 'padStart', 'sort', 'pop', 'shift')
$mrisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($tpl[$i]) { continue }
    $line = $lines[$i]
    if ($line -match '^\s*//') { continue }
    foreach ($m in [regex]::Matches($line, '\.([A-Za-z_][A-Za-z0-9_]*)\s*\(')) {
        $meth = $m.Groups[1].Value
        if ($badMethods -contains $meth) {
            Write-Host ("  [RISK] line {0}: .{1}() -- ucode has no such method" -f ($i + 1), $meth)
            Write-Host ("         {0}" -f $line.Trim())
            $mrisk++
        }
    }
}
Write-Host ""
if ($mrisk -eq 0) { Write-Host "OK: no bad method calls" } else { Write-Host "FAIL: $mrisk bad method calls" }

# 6) 模板字符串里的 HTML onclick 转义检查
#
# 管理页整体是一个反引号模板字符串，里面嵌了生成 HTML 的 JS。
# 要在 JS 字符串里输出「反斜杠 + 单引号」，源码必须写「两个反斜杠 + 单引号」。
# 只写一个反斜杠会被模板字符串吃掉，渲染成两个连续单引号，
# 使整段 script 抛 SyntaxError —— 管理页永远停在「加载中…」。
# 判据：模板字符串区间内，onclick 属性里的引号转义不足即为坏行。
Write-Host ""
Write-Host "=== TEMPLATE ESCAPE CHECK ==="
$BS = [string][char]92
$SQ = [string][char]39
$SINGLE = $BS + $SQ
$DOUBLE = $BS + $BS + $SQ
$erisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if (-not $tpl[$i]) { continue }
    $line = $lines[$i]
    if ([string]::IsNullOrEmpty($line)) { continue }
    if (-not $line.Contains('onclick="')) { continue }
    if (-not $line.Contains($SINGLE)) { continue }
    # 把已正确的双反斜杠形态先挖掉，剩下的单反斜杠就是漏网的
    $probe = $line.Replace($DOUBLE, '')
    if ($probe.Contains($SINGLE)) {
        Write-Host ("  [RISK] line {0}: onclick 引号转义不足" -f ($i + 1))
        Write-Host ("         {0}" -f $line.Trim())
        $erisk++
    }
}
Write-Host ""
if ($erisk -eq 0) { Write-Host "OK: no template escape issues" } else { Write-Host "FAIL: $erisk template escape issues" }

# 7) ucode 不支持的语法
#
# ucode 只有 try/catch，**没有 finally**：`} finally {` 会在编译期报
# "Syntax error: Unexpected token / Expecting 'catch'"。
# 这种错误静态就能发现，不必等拷到路由器上跑 ucode -c。
Write-Host ""
Write-Host "=== UNSUPPORTED SYNTAX CHECK ==="
$srisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($tpl[$i]) { continue }
    $line = $lines[$i]
    if ($line -match '^\s*//') { continue }
    if ($line -match '\bfinally\b') {
        Write-Host ("  [RISK] line {0}: ucode has no 'finally'" -f ($i + 1))
        Write-Host ("         {0}" -f $line.Trim())
        $srisk++
    }
}
Write-Host ""
if ($srisk -eq 0) { Write-Host "OK: no unsupported syntax" } else { Write-Host "FAIL: $srisk unsupported syntax" }

# 8) ucode 没有 undefined 这个标识符
#
# ucode 里 undefined 既不是关键字也不是全局变量：写 `v === undefined` 会在运行期抛
#   Reference error: access to undeclared variable undefined
# 整个进程直接起不来（v1.8.0 首次部署就是这么崩的，8789 完全不监听）。
# 最阴的地方是它**看编译单元而定**：把那段代码抠进独立小文件里跑不报错，
# `ucode -c` 编译期也不报错，46 项单元测试全过照样抓不到。
# 所以只能靠静态扫描 + 纪律来防。注释里、模板字符串里（浏览器 JS）的 undefined 是安全的。
function Test-InString([string]$s, [int]$pos) {
    $sq = 0; $dq = 0; $esc = $false
    for ($k = 0; $k -lt $pos; $k++) {
        $c = $s[$k]
        if ($esc) { $esc = $false; continue }
        if ($c -eq [char]92) { $esc = $true; continue }
        if ($c -eq [char]39) { $sq++ }
        elseif ($c -eq [char]34) { $dq++ }
    }
    return ((($sq % 2) -eq 1) -or (($dq % 2) -eq 1))
}
Write-Host ""
Write-Host "=== UNDEFINED IDENTIFIER CHECK ==="
$urisk = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($tpl[$i]) { continue }
    $line = $lines[$i]
    $code = $line -replace '(?<!:)//.*$', ''
    if ([string]::IsNullOrWhiteSpace($code)) { continue }
    foreach ($m in [regex]::Matches($code, '(?<![A-Za-z0-9_$.])undefined(?![A-Za-z0-9_])')) {
        if (Test-InString $code $m.Index) { continue }
        Write-Host ("  [RISK] line {0}: bare 'undefined' identifier" -f ($i + 1))
        Write-Host ("         {0}" -f $line.Trim())
        $urisk++
    }
}
Write-Host ""
if ($urisk -eq 0) { Write-Host "OK: no bare 'undefined' identifier" } else { Write-Host "FAIL: $urisk bare 'undefined' identifier(s)" }

# 6) 全局声明顺序检查 —— ucode 不提升声明
#
# ucode 按**定义时的词法作用域**解析标识符：函数体里引用一个顶层 let/const，
# 而那个声明出现在函数定义**之后**，运行到那一行就会抛
#   Reference error: access to undeclared variable <name>
#
# 为什么必须静态查：这个错误**只在真正执行到那行时才炸**，
#   * `ucode -c` 语法检查通过（不是语法错误）；
#   * 单元测试也通过 —— 只要测试的 prelude 里恰好先声明了同名变量；
#   * 平时看着一切正常，直到线上走进那条分支，服务直接死掉、procd 拉起来再死。
# v1.8.1 的 brakeNoteRateLimit()（行1471 用 cfg，而 cfg 在行2842 才声明）
# 就是这么把服务打成崩溃-重启循环的，日志里只能看到 pid 连续变化。
Write-Host ""
Write-Host "=== GLOBAL DECLARATION ORDER CHECK ==="
$globals = @{}
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($tpl[$i]) { continue }
    if ($lines[$i] -match '^(let|const)\s+([A-Za-z_][A-Za-z0-9_]*)') {
        $gn = $Matches[2]
        if (-not $globals.ContainsKey($gn)) { $globals[$gn] = $i + 1 }
    }
}

$grisk = 0
foreach ($n in $defs.Keys) {
    $s = $defs[$n] - 1
    $e = $endOf[$n] - 1

    # 同名局部声明会遮蔽全局，必须先摘掉，否则全是误报：
    #   * 形参 —— `function loadPool(cfg) {` 里的 cfg 是参数，跟全局 cfg 无关；
    #   * 函数体内的 let/const —— `loadConfig()` 里就有 `let cfg = {`，
    #     该函数通篇用的是自己的局部 cfg。
    # 不摘这些，第二版检查仍会刷出 71 条假 RISK。
    $shadow = @{}
    if ($lines[$s] -match '\(([^)]*)\)') {
        foreach ($p in ($Matches[1] -split ',')) {
            $pn = ($p -replace '^\s+', '') -replace '\s*=.*$', ''
            if ($pn -match '^[A-Za-z_][A-Za-z0-9_]*$') { $shadow[$pn] = $true }
        }
    }
    for ($i = $s; $i -lt $e; $i++) {
        if ($tpl[$i]) { continue }
        $c = $lines[$i] -replace '(?<!:)//.*$', ''
        foreach ($m in [regex]::Matches($c, '(?<![A-Za-z0-9_.$])(?:let|const)\s+([A-Za-z_][A-Za-z0-9_]*)')) {
            $shadow[$m.Groups[1].Value] = $true
        }
    }

    $late = @($globals.Keys | Where-Object { $globals[$_] -gt ($s + 1) -and -not $shadow.ContainsKey($_) })
    if ($late.Count -eq 0) { continue }
    $rx = '(?<![A-Za-z0-9_.$])(' + (($late | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![A-Za-z0-9_])'
    for ($i = $s; $i -lt $e; $i++) {
        if ($tpl[$i]) { continue }
        $code = $lines[$i] -replace '(?<!:)//.*$', ''
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        foreach ($m in [regex]::Matches($code, $rx)) {
            $g = $m.Groups[1].Value
            Write-Host ("  [RISK] {0}() 行{1} 引用 {2}，而它行{3} 才声明" -f $n, ($i + 1), $g, $globals[$g])
            Write-Host ("         {0}" -f $lines[$i].Trim())
            $grisk++
        }
    }
}
Write-Host ""
if ($grisk -eq 0) { Write-Host "OK: no global referenced before its declaration" } else { Write-Host "FAIL: $grisk reference(s) before declaration" }
