$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = [System.Collections.Generic.List[string]]::new()

function Read-OrEmpty([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path
    }
    return ''
}

function Decode-Base64Utf8([string]$Value) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Get-QQuoteClosingDelimiter([char]$OpenDelimiter) {
    switch ($OpenDelimiter) {
        '[' { return ']' }
        '(' { return ')' }
        '{' { return '}' }
        '<' { return '>' }
        default { return [string]$OpenDelimiter }
    }
}

function Remove-SqlComments([string]$Text) {
    $builder = New-Object System.Text.StringBuilder
    $i = 0

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]

        if ($ch -eq "'") {
            [void]$builder.Append($ch)
            $i++
            while ($i -lt $Text.Length) {
                $current = $Text[$i]
                [void]$builder.Append($current)
                $i++
                if ($current -eq "'") {
                    if ($i -lt $Text.Length -and $Text[$i] -eq "'") {
                        [void]$builder.Append($Text[$i])
                        $i++
                        continue
                    }
                    break
                }
            }
            continue
        }

        if (($ch -eq 'q' -or $ch -eq 'Q') -and $i + 2 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
            $openDelimiter = $Text[$i + 2]
            $closeDelimiter = Get-QQuoteClosingDelimiter $openDelimiter
            [void]$builder.Append($ch)
            [void]$builder.Append("'")
            [void]$builder.Append($openDelimiter)
            $i += 3

            while ($i -lt $Text.Length) {
                $current = $Text[$i]
                [void]$builder.Append($current)
                $i++
                if ($current -eq $closeDelimiter -and $i -lt $Text.Length -and $Text[$i] -eq "'") {
                    [void]$builder.Append($Text[$i])
                    $i++
                    break
                }
            }
            continue
        }

        if ($ch -eq '-' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '-') {
            $i += 2
            while ($i -lt $Text.Length -and $Text[$i] -ne "`r" -and $Text[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($ch -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) {
                $i++
            }
            if ($i + 1 -lt $Text.Length) {
                $i += 2
            }
            continue
        }

        [void]$builder.Append($ch)
        $i++
    }

    return $builder.ToString()
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Label) {
    if (-not [regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $script:failures.Add("Missing [$Label]: pattern $Pattern")
    }
}

function Assert-NotMatch([string]$Text, [string]$Pattern, [string]$Label) {
    if ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline)) {
        $script:failures.Add("Forbidden [$Label]: pattern $Pattern")
    }
}

function Assert-RegexCount([string]$Text, [string]$Pattern, [int]$ExpectedCount, [string]$Label) {
    $count = [regex]::Matches($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline).Count
    if ($count -ne $ExpectedCount) {
        $script:failures.Add("Unexpected count [$Label]: expected $ExpectedCount actual $count pattern $Pattern")
    }
}

function Get-CreateJobCallText([string]$Text) {
    $match = [regex]::Match(
        $Text,
        'DBMS_SCHEDULER\.CREATE_JOB\s*\(',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        return ''
    }

    $start = $match.Index + $match.Length
    $depth = 1
    $i = $start
    $builder = New-Object System.Text.StringBuilder

    while ($i -lt $Text.Length -and $depth -gt 0) {
        $ch = $Text[$i]

        if ($ch -eq "'") {
            [void]$builder.Append($ch)
            $i++
            while ($i -lt $Text.Length) {
                $current = $Text[$i]
                [void]$builder.Append($current)
                $i++
                if ($current -eq "'") {
                    if ($i -lt $Text.Length -and $Text[$i] -eq "'") {
                        [void]$builder.Append($Text[$i])
                        $i++
                        continue
                    }
                    break
                }
            }
            continue
        }

        if (($ch -eq 'q' -or $ch -eq 'Q') -and $i + 2 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
            $openDelimiter = $Text[$i + 2]
            $closeDelimiter = Get-QQuoteClosingDelimiter $openDelimiter
            [void]$builder.Append($ch)
            [void]$builder.Append("'")
            [void]$builder.Append($openDelimiter)
            $i += 3

            while ($i -lt $Text.Length) {
                $current = $Text[$i]
                [void]$builder.Append($current)
                $i++
                if ($current -eq $closeDelimiter -and $i -lt $Text.Length -and $Text[$i] -eq "'") {
                    [void]$builder.Append($Text[$i])
                    $i++
                    break
                }
            }
            continue
        }

        if ($ch -eq '(') {
            $depth++
            [void]$builder.Append($ch)
            $i++
            continue
        }

        if ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) {
                break
            }
            [void]$builder.Append($ch)
            $i++
            continue
        }

        [void]$builder.Append($ch)
        $i++
    }

    if ($depth -eq 0) {
        return $builder.ToString()
    }

    return ''
}

function Get-JobActionBlock([string]$Text) {
    $match = [regex]::Match(
        $Text,
        "job_action\s*=>\s*q'\[(?<body>.*?)\]'",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
    )

    if ($match.Success) {
        return $match.Groups['body'].Value
    }

    return ''
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Label) {
    if (-not $Text.Contains($Needle)) {
        $script:failures.Add("Missing [$Label]: $Needle")
    }
}

function Assert-NotContainsInsensitive([string]$Text, [string]$Needle, [string]$Label) {
    if ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $script:failures.Add("Forbidden [$Label]: $Needle")
    }
}

function Assert-True([bool]$Condition, [string]$Label) {
    if (-not $Condition) {
        $script:failures.Add("Expected true [$Label]")
    }
}

function Assert-False([bool]$Condition, [string]$Label) {
    if ($Condition) {
        $script:failures.Add("Expected false [$Label]")
    }
}

function Get-LineStartClientCommandPattern {
    $commandAlternatives = @(
        ('SE' + 'T\b'),
        ('PRO' + 'MPT\b'),
        ('IN' + 'FO\b'),
        ('DD' + 'L\b'),
        ('HIS' + 'TORY\b'),
        ('EX' + 'EC(?:' + 'UTE' + ')?\b(?!\s+IMMEDIATE\b)'),
        ('SP' + 'OOL\b'),
        ('ACC' + 'EPT\b'),
        ('DEF' + 'INE\b'),
        ('UNDEF' + 'INE\b'),
        ('C' + 'OLUMN\b'),
        ('VAR' + 'IABLE\b'),
        ('PR' + 'INT\b'),
        ('WHE' + 'NEVER\b'),
        ('HO' + 'ST\b'),
        ('PA' + 'USE\b'),
        ('R' + 'EM\b'),
        (('CON' + 'NECT') + '\b(?!\s+(?:TO|BY)\b)'),
        '@{1,2}(?=\s|$)'
    )
    return '^\s*(?:' + ($commandAlternatives -join '|') + ')'
}

function Test-LineStartClientCommand([string]$Text) {
    return [regex]::IsMatch(
        $Text,
        (Get-LineStartClientCommandPattern),
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Assert-NoLineStartClientCommands([string]$Text, [string]$Label) {
    if ([regex]::IsMatch(
            $Text,
            (Get-LineStartClientCommandPattern),
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline
        )) {
        $script:failures.Add("Forbidden [$Label]: line-start client command")
    }
}

Assert-True (Test-LineStartClientCommand 'INFO archive metadata') 'self-test: INFO'
Assert-True (Test-LineStartClientCommand 'DDL create table t (id number);') 'self-test: DDL'
Assert-True (Test-LineStartClientCommand 'HISTORY show restore plan') 'self-test: HISTORY'
Assert-True (Test-LineStartClientCommand 'CONNECT archive_user/password') 'self-test: CONNECT'
Assert-False (Test-LineStartClientCommand 'CONNECT TO prod_ro_link') 'self-test: CONNECT TO'
Assert-False (Test-LineStartClientCommand 'CONNECT BY PRIOR emp_id = mgr_id') 'self-test: CONNECT BY PRIOR'
Assert-False (Test-LineStartClientCommand "EXECUTE IMMEDIATE 'select 1 from dual'") 'self-test: EXECUTE IMMEDIATE'

$sqlFiles = Get-ChildItem -File -LiteralPath $root -Filter '*.sql' | Sort-Object Name
$deliveryText = ($sqlFiles | ForEach-Object { Read-OrEmpty $_.FullName }) -join "`n"
$deliveryText += "`n" + (Read-OrEmpty (Join-Path $root 'README.md'))

$tables = Read-OrEmpty (Join-Path $root '02_archive_control_tables.sql')
$schemaSetup = Read-OrEmpty (Join-Path $root '01_archive_schema_setup.sql')
$package = Read-OrEmpty (Join-Path $root '04_archive_package.sql')
$scheduler = Read-OrEmpty (Join-Path $root '05_archive_scheduler_job.sql')
$examples = Read-OrEmpty (Join-Path $root '07_custom_sync_examples.sql')
$readme = Read-OrEmpty (Join-Path $root 'README.md')
$packageForStaticChecks = $package -replace 'REGEXP_LIKE\(\s*data_type,\s*', 'REGEXP_LIKE(data_type, '
$schedulerWithoutComments = Remove-SqlComments $scheduler
$createJobText = Get-CreateJobCallText $schedulerWithoutComments
$jobAction = Get-JobActionBlock $schedulerWithoutComments

Assert-Contains $package 'CREATE OR REPLACE PACKAGE history_archive_pkg AS' 'package name'
Assert-Contains $package 'PROCEDURE sync_full(' 'full interface'
Assert-Contains $package 'PROCEDURE sync_incremental(' 'incremental interface'
Assert-Contains $package 'PROCEDURE sync_incremental_where(' 'filtered interface'
Assert-Contains $package 'PROCEDURE validate_partition_column(' 'partition validator'
Assert-Contains $package 'PARTITION BY RANGE (' 'range partition DDL'
Assert-Contains $package "INTERVAL (NUMTOYMINTERVAL(1, ''MONTH''))" 'monthly interval DDL'
Assert-Contains $package 'PARTITION P_BEFORE_2000' 'seed partition'
Assert-Contains $packageForStaticChecks "REGEXP_LIKE(data_type, '^TIMESTAMP(" 'plain TIMESTAMP validation'
Assert-Contains $package "INSTR(v_where, ':') > 0" 'runtime bind rejection'
Assert-Contains $package 'INSERT INTO ' 'single copy statement'
Assert-Contains $package 'COMMIT;' 'successful commit'
Assert-Contains $package 'SQL%ROWCOUNT' 'inserted row output'

$forbiddenPackage = @(
    'CREATE INDEX',
    'CREATE UNIQUE INDEX',
    'user_indexes',
    'user_ind_columns',
    'key_columns',
    'NOT EXISTS',
    'archive_batch_log',
    'archive_validation_result',
    'archive_error_log',
    'PROCEDURE preview(',
    'FUNCTION get_batch_summary(',
    'validate_batch',
    'ARC_BATCH_ID',
    'ARC_ARCHIVED_AT',
    'batch_size',
    'max_batches_per_run'
)
foreach ($needle in $forbiddenPackage) {
    Assert-NotContainsInsensitive $package $needle "minimal package: $needle"
}

$forbiddenDelivery = @(
    ('SQL' + '*Plus'),
    ('WHENEVER' + ' SQLERROR'),
    ('SQL' + '.SQLCODE'),
    ('SHOW' + ' ERRORS'),
    ('FROM' + ' user_errors'),
    ('Package compilation' + ' failed')
)
foreach ($needle in $forbiddenDelivery) {
    Assert-NotContainsInsensitive $deliveryText $needle "delivery bundle: $needle"
}

Assert-NoLineStartClientCommands $deliveryText 'delivery bundle'

$forbiddenTables = @(
    'CREATE TABLE archive_batch_log',
    'CREATE TABLE archive_validation_result',
    'CREATE TABLE archive_error_log',
    'CREATE INDEX',
    'key_columns',
    'NOT EXISTS',
    'ARC_BATCH_ID',
    'ARC_ARCHIVED_AT',
    'batch_size',
    'max_batches_per_run',
    'where_clause_extra'
)
foreach ($needle in $forbiddenTables) {
    Assert-NotContainsInsensitive $tables $needle "minimal tables: $needle"
}

Assert-NotContainsInsensitive $schemaSetup 'archive_idx' 'schema setup: archive_idx tablespace or quota'
Assert-Contains $schemaSetup 'GRANT CREATE JOB TO archive_admin;' 'scheduler privilege'

Assert-RegexCount $schedulerWithoutComments 'DBMS_SCHEDULER\.CREATE_JOB\s*\(' 1 'scheduler create_job count'
Assert-Match $schedulerWithoutComments 'ARCHIVE_ORDER_HEADERS_DAILY_JOB' 'scheduler job name'
Assert-Match $schedulerWithoutComments 'PLSQL_BLOCK' 'scheduler job type'
Assert-Match $schedulerWithoutComments 'c_archive_lag_days\s+CONSTANT\s+PLS_INTEGER\s*:=\s*1;' 'scheduler lag constant'
Assert-Match $schedulerWithoutComments "AT\s+TIME\s+ZONE\s+'Asia/Shanghai'" 'scheduler timezone'
Assert-Match $createJobText 'repeat_interval\s*=>\s*''FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0''' 'scheduler repeat interval'
Assert-Match $createJobText 'enabled\s*=>\s*FALSE' 'scheduler disabled'
Assert-Match $createJobText 'auto_drop\s*=>\s*FALSE' 'scheduler auto_drop false'
Assert-Match $createJobText "start_date\s*=>\s*SYSTIMESTAMP\s+AT\s+TIME\s+ZONE\s+'Asia/Shanghai'" 'scheduler start date timezone'
Assert-NotMatch $schedulerWithoutComments 'history_archive_pkg\.sync_full\s*\(' 'scheduler no full sync in file'
Assert-RegexCount $jobAction 'history_archive_pkg\.sync_incremental\s*\(' 1 'scheduler incremental call count'
Assert-NotMatch $jobAction 'history_archive_pkg\.sync_full\s*\(' 'scheduler no full sync in action'
Assert-NotMatch $jobAction 'history_archive_pkg\.sync_incremental_where\s*\(' 'scheduler no filtered sync in action'
Assert-Match $jobAction "history_archive_pkg\.sync_incremental\s*\(\s*'ORDERS'\s*,\s*'ORDER_HEADERS'\s*,\s*v_start_date\s*,\s*v_end_date\s*\)" 'scheduler exact source table arguments'
Assert-Match $jobAction "v_today\s+DATE\s*:=\s*TRUNC\s*\(\s*CAST\s*\(\s*SYSTIMESTAMP\s+AT\s+TIME\s+ZONE\s+'Asia/Shanghai'\s+AS\s+DATE\s*\)\s*\)" 'scheduler v_today expression'
Assert-Match $jobAction 'v_end_date\s+DATE\s*:=\s*v_today\s*-\s*c_archive_lag_days' 'scheduler v_end_date expression'
Assert-Match $jobAction 'v_start_date\s+DATE\s*:=\s*v_end_date\s*-\s*1' 'scheduler v_start_date expression'
Assert-NotMatch $jobAction '\b(FOR|WHILE|LOOP)\b' 'scheduler no loops in action'
Assert-NotMatch $jobAction '\bCOMMIT\b' 'scheduler no commit in action'

Assert-Contains $examples 'history_archive_pkg.sync_full' 'full example'
Assert-Contains $examples 'history_archive_pkg.sync_incremental' 'incremental example'
Assert-Contains $examples 'history_archive_pkg.sync_incremental_where' 'filtered example'
Assert-NotContainsInsensitive $examples 'preview(' 'no preview example'
Assert-NotContainsInsensitive $examples 'get_batch_summary(' 'no summary example'

Assert-Contains $readme (Decode-Base64Utf8 '5LiN5Yib5bu657Si5byV') 'README no indexes'
Assert-Contains $readme (Decode-Base64Utf8 '5LiN5YaZ5pel5b+X') 'README no logs'
Assert-Contains $readme (Decode-Base64Utf8 '5LiN5YGa5Y676YeN') 'README no deduplication'
Assert-Contains $readme (Decode-Base64Utf8 '6YeN5aSN5omn6KGM5Lya5YaN5qyh5o+S5YWl6YeN5aSN6K6w5b2V') 'README duplicate reruns'
Assert-Contains $readme (Decode-Base64Utf8 'IyBPcmFjbGUg5Y6G5Y+y5pWw5o2u5b2S5qGj') 'README title'
Assert-Contains $readme (Decode-Base64Utf8 'IyMg5a6J6KOF6aG65bqP') 'README install heading'
Assert-Contains $readme 'DBMS_SCHEDULER.RUN_JOB(' 'README run job'
Assert-Contains $readme 'DBMS_SCHEDULER.ENABLE(' 'README enable job'
Assert-Contains $readme 'DBMS_SCHEDULER.DISABLE(' 'README disable job'
Assert-Contains $readme 'USER_SCHEDULER_JOB_RUN_DETAILS' 'README run details view'
Assert-NotContainsInsensitive $readme 'force => TRUE' 'README disable force'
Assert-Contains $readme "p_range_end_date => DATE '2026-07-15'" 'README cutover full sync example'
Assert-Contains $readme "[2026-07-15, 2026-07-16)" 'README first scheduler window example'
Assert-Contains $readme 'history_archive_pkg.sync_full(' 'README full sync cutover call'
Assert-Contains $readme (Decode-Base64Utf8 '5LiN6KaB5Zyo5bey57uP5b2S5qGj5aKe6YeP56qX5Y+j5ZCO77yM5YaN5qyh5omn6KGM5peg6ZmQ5Yi25oiW5pe26Ze06IyD5Zu06YeN5Y+g55qE5YWo6YeP5ZCM5q2l77yM5Zug5Li65b2T5YmN54mI5pys5LiN5YGa5Y676YeN44CC') 'README no overlapping full sync warning'
Assert-Contains $readme (Decode-Base64Utf8 '5Lqk5LuY6IyD5Zu055qE56aB55So5a2Q5Liy5qOA5p+l5ZKM6KGM6aaW5a6i5oi356uv5ZG95Luk5qOA5p+l5LuN54S25Lya5a+55pW05Liq5Lqk5LuY5YaF5a655L+d5oyB5rOo6YeK5pWP5oSf77yb6ICMIFNjaGVkdWxlciDor63kuYnmo4Dmn6XkvJrlnKjliIbmnpDliY3lhYjljrvpmaQgU1FMIOazqOmHiuOAgg==') 'README static scan note'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Archive SQL minimal contract failed with $($failures.Count) issue(s)."
}

Write-Output 'PASS: archive SQL minimal contract checks'
