<#
 run_all.ps1 - builds the benchmark programs and runs the experiments behind Figs. 11-21.

 Examples
   .\run_all.ps1                         # everything, 1..16 threads, 1 repetition
   .\run_all.ps1 -Figures 11,13          # only some figures
   .\run_all.ps1 -Figures 15,16 -RunSec 10 -Repeats 3
   .\run_all.ps1 -SkipBuild              # reuse previous build

 Output: results\<figure>\<series>.r<rep>.csv  with columns  threads,ops_per_sec
#>
param(
    [int[]]  $Figures    = (11..21),
    [int]    $MaxThreads = [Environment]::ProcessorCount,
    [int]    $Repeats    = 1,
    [int]    $RunSec     = 15,  # YCSB runs (Figs. 15, 16): seconds per data point
    [string] $Repo       = ".",
    [string] $Out        = ".\results",
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path $Repo).Path
$Bin  = Join-Path (Get-Location).Path "bin_out"
New-Item -ItemType Directory -Force -Path $Out, "$Out\logs" | Out-Null
$Out  = (Resolve-Path $Out).Path

# ---------------------------------------------------------------- build
$projects = @{
    list   = "samples\ResizableListBench\ResizableListBench.csproj"
    micro  = "samples\epvs\EpvsMicrobench\EpvsMicrobench.csproj"
    nest   = "samples\NestingMicrobench\NestingMicrobench.csproj"
    phase  = "samples\PhaseMicrobench\PhaseMicrobench.csproj"
    share  = "samples\EpochSharingMicrobench\EpochSharingMicrobench.csproj"
    ycsb   = "benchmark\FASTER.benchmark.csproj"
}
if (-not $SkipBuild) {
    foreach ($k in $projects.Keys) {
        Write-Host "== building $k"
        $extra = @(); if ($k -eq "ycsb") { $extra = @("-p:Platform=x64") }
        dotnet publish (Join-Path $Repo $projects[$k]) -c Release -o (Join-Path $Bin $k) @extra --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw "build failed for $k" }
    }
}
function Exe($k) {
    $rc = Get-ChildItem (Join-Path $Bin $k) -Filter *.runtimeconfig.json | Select-Object -First 1
    if (-not $rc) { throw "no build output for $k in $Bin\$k" }
    return (Join-Path $Bin $k) + "\" + $rc.Name.Replace(".runtimeconfig.json", ".exe")
}

# ---------------------------------------------------------------- runner
# One data point = one process launch; the program appends its throughput (ops/s) to a tmp file.
function Sweep {
    param([string]$Dir, [string]$Series, [string]$Prog, [scriptblock]$ArgsFor, [int]$Max = $MaxThreads, [string]$OutFlag = "-u")
    $exe = Exe $Prog
    New-Item -ItemType Directory -Force -Path "$Out\$Dir" | Out-Null
    for ($r = 1; $r -le $Repeats; $r++) {
        $csv = "$Out\$Dir\$Series.r$r.csv"
        "threads,ops_per_sec" | Set-Content $csv
        for ($t = 1; $t -le $Max; $t++) {
            $tmp = "$Out\.tmp.txt"; Remove-Item $tmp -ErrorAction SilentlyContinue
            $a = @(& $ArgsFor $t) + @($OutFlag, $tmp)
            Write-Host ("[{0}/{1}] rep {2}  threads {3}/{4}" -f $Dir, $Series, $r, $t, $Max)
            $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            & $exe @a *>> "$Out\logs\$Dir-$Series.log"
            $ErrorActionPreference = $old
            if ((Test-Path $tmp) -and (Get-Content $tmp)) { "$t," + (Get-Content $tmp | Select-Object -Last 1) | Add-Content $csv }
            else { Write-Warning "no result for $Dir/$Series threads=$t (see $Out\logs\$Dir-$Series.log)" }
        }
    }
}

function L($d, $series, $p, $extra = @(), $init = 1000000) {
    Sweep $d $series "list" { param($t) @("-d", $series, "-t", $t, "-n", 0, "-p", $p, "-i", $init) + $extra }
}

foreach ($fig in $Figures) { switch ($fig) {

 # ---- Fig. 11: resizable array, read/write only (p = 0%), 1M initial elements
 11 { foreach ($s in "latch-free-mock","latched","simple-version","simple-version-pinned","bravo") { L "fig11" $s "0" } }

 # ---- Fig. 12: push-heavy workloads from a (nearly) empty array; a,b,c = p 10%, 50%, 100%
 12 { foreach ($pp in @(@("fig12_p10","1e-1"), @("fig12_p50","5e-1"), @("fig12_p100","1"))) {
        foreach ($s in "latch-free-mock","latched","simple-version","two-phase-version","simple-version-pinned","bravo") {
            L $pp[0] $s $pp[1] @() 1 } } }

 # ---- Fig. 13: p = 100% with a 10 ms delay inside every resize
 13 { foreach ($s in "simple-version","two-phase-version","bravo") { L "fig13" $s "1" @("--resize-delay","10") 1 } }

 # ---- Fig. 14: tiny (128-entry) epoch table / BRAVO table, p = 0%
 14 { foreach ($s in "simple-version","simple-version-pinned","bravo") { L "fig14" $s "0" @("-e","128") } }

 # ---- Fig. 15: FASTER YCSB 50:50 uniform, remote-key validation: none | reader-writer latch | EPVS
 15 { foreach ($v in @(@("none","no-validation"), @("base","reader-writer-latch"), @("epvs","epvs"))) {
        $val = $v[0]
        Sweep "fig15" $v[1] "ycsb" { param($t) @("-t",$t,"-n",0,"--noaff=true","--synth=true","--validation=$val","--runsec=$RunSec") } -OutFlag "--output-file" } }

 # ---- Fig. 16: FASTER-KV checkpointing; a/b = 500 ms, c/d = 25 ms; fine (--noaff true) / coarse (--noaff false)
 16 { $cases = @(@("fig16_a_500ms_fine",500,"true"), @("fig16_b_500ms_coarse",500,"false"),
                 @("fig16_c_25ms_fine",25,"true"),  @("fig16_d_25ms_coarse",25,"false"))
      foreach ($c in $cases) { foreach ($e in @(@("original","false"), @("epvs","true"))) {
        $ms = $c[1]; $aff = $c[2]; $useEpvs = $e[1]
        Sweep $c[0] $e[0] "ycsb" { param($t) @("-t",$t,"-n",0,"--synth=true","--noaff=$aff","--chkptms=$ms","--useepvs=$useEpvs","--runsec=$RunSec") } -Max ([Math]::Min($MaxThreads,24)) -OutFlag "--output-file" } } }

 # ---- Fig. 17: version-change frequency (a: EPVS, b: BRAVO). Fewer ops for large p so runs stay short.
 17 { $ps = @(@("p=0","0",1000000), @("p=1e-5","1e-5",1000000), @("p=1e-4","1e-4",1000000), @("p=1e-3","1e-3",1000000),
              @("p=1e-2","1e-2",100000), @("p=1e-1","1e-1",10000), @("p=1","1",10000))
      foreach ($m in "latch-free","latch") { $mm = $m
          Sweep "fig17_epvs" $(if ($m -eq "latch") {"latched"} else {$m}) "micro" { param($t) @("-m",$mm,"-t",$t,"-n",0,"-e",4096) } }
      foreach ($x in $ps) { $pv = $x[1]; $ops = $x[2]
          Sweep "fig17_epvs"  $x[0] "micro" { param($t) @("-m","epvs", "-t",$t,"-n",0,"-e",4096,"-p",$pv,"-o",$ops) }
          Sweep "fig17_bravo" $x[0] "micro" { param($t) @("-m","bravo","-t",$t,"-n",0,"-e",4096,"-p",$pv,"-o",$ops) } } }

 # ---- Fig. 18: epoch-table size sensitivity (a: enter/leave, b: refresh, c: BRAVO), p = 1e-4
 18 { foreach ($pn in @(@("fig18_enter_leave","epvs"), @("fig18_refresh","epvs-refresh"), @("fig18_bravo","bravo"))) {
        foreach ($e in 64,128,256,512,1024) { $mode = $pn[1]; $ee = $e
            Sweep $pn[0] "e=$e" "micro" { param($t) @("-m",$mode,"-t",$t,"-n",0,"-e",$ee,"-p","1e-4") } } } }

 # ---- Fig. 19: number of phases in the state machine (total work per version change fixed at 100 hash units)
 19 { foreach ($n in 1,10,100) { $nn = $n
        Sweep "fig19" "n=$n" "phase" { param($t) @("-t",$t,"-n",$nn,"-l",100,"-e",4096) } } }

 # ---- Fig. 20: nesting (1 vs 4 nested protections), no version changes
 20 { foreach ($c in @(@("EPVS","epvs-noshare"), @("BRAVO","bravo"))) { foreach ($i in 1,4) { $mode = $c[1]; $ii = $i
        Sweep "fig20" ("{0}-{1}" -f $c[0], $i) "nest" { param($t) @("-m",$mode,"-i",$ii,"-t",$t,"-n",0,"-p","0") } } } }

 # ---- Fig. 21: epoch sharing, 8 instances, p = 1e-4  (a: all threads share one instance, b: no sharing)
 21 { foreach ($k in "share","noshare") { foreach ($c in @(@("EPVS","epvs"), @("BRAVO","bravo"), @("Latch","latch"))) { $mode = "{0}-{1}" -f $c[1], $k
        Sweep "fig21_$k" $c[0] "share" { param($t) @("-m",$mode,"-i",8,"-t",$t,"-n",0,"-p","1e-4") } } } }
} }
Write-Host "`nAll requested runs finished. Now: python plot_figures.py"
