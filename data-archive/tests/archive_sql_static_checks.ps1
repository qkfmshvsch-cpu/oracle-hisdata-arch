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
Assert-Contains $package 'PROCEDURE sync(' 'sync interface'
Assert-Contains $package 'PROCEDURE sync_where(' 'filtered sync interface'
Assert-RegexCount $package 'PROCEDURE\s+sync\s*\(' 2 'sync declaration and body count'
Assert-RegexCount $package 'PROCEDURE\s+sync_where\s*\(' 2 'sync_where declaration and body count'
Assert-NotContainsInsensitive $package 'sync_full' 'old full interface removed'
Assert-NotContainsInsensitive $package 'sync_incremental' 'old incremental interfaces removed'
Assert-NotContainsInsensitive $package 'p_start_date' 'explicit start date removed'
Assert-NotContainsInsensitive $package 'p_end_date' 'explicit end date removed'
Assert-NotContainsInsensitive $package 'p_sync_mode' 'sync mode removed'
Assert-NotContainsInsensitive $package "'FULL'" 'full mode removed'
Assert-NotContainsInsensitive $package "'INCREMENTAL'" 'incremental mode removed'
Assert-Match $package 'p_extra_where\s+IN\s+VARCHAR2[\s\S]*p_batch_days\s+IN\s+PLS_INTEGER\s+DEFAULT\s+1' 'sync_where parameter order'
Assert-Match $package 'normalize_where\(\s*p_extra_where,\s*''p_extra_where'',\s*TRUE,\s*v_runtime_where\s*\)' 'sync_where required condition validation'
Assert-Match $package 'v_predicate\s*:=\s*TRIM\(\s*SUBSTR\(\s*v_where,\s*4\s*\)\s*\)' 'filtered predicate strips leading AND'
Assert-Match $package 'p_result\s*:=\s*''AND \(''\s*\|\|\s*v_predicate\s*\|\|\s*''\)''' 'filtered predicate is grouped'
Assert-Match $package 'IF\s+NOT\s+REGEXP_LIKE\(\s*v_validation_where' 'source alias validation ignores literals'
Assert-Match $package 'REGEXP_LIKE\(\s*v_validation_where,[\s\S]*SELECT\|UNION\|INTERSECT\|MINUS\|WITH' 'query-shaping tokens rejected outside literals'
Assert-Contains $package "SUBSTR(v_where, v_pos + 1, 1) = '''' THEN" 'doubled quote handling'
Assert-Contains $package 'contains an unterminated literal.' 'unterminated literal rejection'
Assert-Contains $package 'v_parenthesis_depth PLS_INTEGER := 0;' 'parenthesis depth state'
Assert-Match $package 'v_parenthesis_depth\s*:=\s*v_parenthesis_depth\s*\+\s*1' 'opening parenthesis increases depth outside literals'
Assert-Match $package 'v_parenthesis_depth\s*:=\s*v_parenthesis_depth\s*-\s*1[\s\S]*IF\s+v_parenthesis_depth\s*<\s*0\s+THEN' 'closing parenthesis rejects early close'
Assert-Match $package 'IF\s+v_parenthesis_depth\s*<>\s*0\s+THEN' 'final parenthesis depth must be zero'
Assert-Contains $package 'contains unbalanced parentheses.' 'unbalanced parenthesis rejection'
Assert-Match $package 'ELSIF\s+\(\s*v_char\s*=\s*''Q''\s+OR\s+v_char\s*=\s*''q''\s*\)[\s\S]*SUBSTR\(\s*v_where,\s*v_pos\s*\+\s*1,\s*1\s*\)\s*=\s*''{2,}\s+THEN' 'runtime q-quote rejection before literal scan'
Assert-Contains $package 'contains unsupported runtime q-quoted literal syntax.' 'runtime q-quote rejection message'
Assert-Match $package 'v_bounds_sql\s*:=\s*v_bounds_sql\s*\|\|\s*'' ''\s*\|\|\s*v_runtime_where' 'filtered source bounds direct append'
Assert-Match $package 'v_sql\s*:=\s*v_sql\s*\|\|\s*'' ''\s*\|\|\s*v_runtime_where' 'filtered batch insert'
Assert-RegexCount $package 'v_runtime_where\s+VARCHAR2\(32767\)' 2 'grouped runtime condition buffers'
$unparenthesizedOrWhere = "AND s.status = 'CLOSED' OR s.status = 'CANCELLED'"
$groupedOrWhere = 'AND (' + $unparenthesizedOrWhere.Substring(4).Trim() + ')'
Assert-True ($groupedOrWhere -eq "AND (s.status = 'CLOSED' OR s.status = 'CANCELLED')") 'unparenthesized OR is grouped'
$earlyCloseOrWhere = "AND s.status = 'CLOSED') OR (s.status = 'CANCELLED'"
Assert-True ($earlyCloseOrWhere -eq "AND s.status = 'CLOSED') OR (s.status = 'CANCELLED'") 'early-close OR predicate fixture'
$runtimeQQuotedWhere = "AND s.status = q'[CLOSED]'"
Assert-True ($runtimeQQuotedWhere -eq "AND s.status = q'[CLOSED]'") 'runtime q-quoted predicate fixture'
Assert-Match $package 'p_retention_periods\s+IN\s+PLS_INTEGER' 'retention-periods interface'
Assert-NotContainsInsensitive $package 'p_retention_days' 'old retention-days interface removed'
Assert-Match $package 'p_batch_days\s+IN\s+PLS_INTEGER\s+DEFAULT\s+1' 'batch-days interface'
Assert-Contains $package 'PROCEDURE detect_source_interval(' 'source interval detector'
Assert-Contains $package 'PROCEDURE validate_partition_column(' 'partition validator'
Assert-Contains $package 'PARTITION BY RANGE (' 'range partition DDL'
Assert-Contains $package "INTERVAL (NUMTOYMINTERVAL(1, ''MONTH''))" 'monthly interval DDL'
Assert-Contains $package 'PARTITION P_BEFORE_2000' 'seed partition'
Assert-Contains $package 'all_part_tables@' 'source partition table metadata'
Assert-Contains $package 'all_part_key_columns@' 'source partition key metadata'
Assert-Contains $package 'Source partition key mismatch for ' 'partition key mismatch source table'
Assert-Contains $package "p_cfg.source_schema || '.' || p_cfg.source_table" 'partition key mismatch source schema.table'
Assert-Contains $package 'expected configured date_column ' 'partition key mismatch expected date column'
Assert-Contains $package 'actual key column ' 'partition key mismatch actual key column'
Assert-Contains $package 'key count ' 'partition key mismatch key count'
Assert-Contains $package 'Unsupported source INTERVAL expression for ' 'unsupported interval source table'
Assert-Contains $package 'actual interval expression ' 'unsupported interval actual expression'
Assert-Contains $packageForStaticChecks "REGEXP_LIKE(data_type, '^TIMESTAMP(" 'plain TIMESTAMP validation'
Assert-Contains $package "INSTR(v_where, ':') > 0" 'runtime bind rejection'
Assert-Contains $package 'INSERT INTO ' 'single copy statement'
Assert-Contains $package 'COMMIT;' 'successful commit'
Assert-Contains $package 'SQL%ROWCOUNT' 'inserted row output'
Assert-Contains $package "'^NUMTODSINTERVAL\(([1-9][0-9]*),''DAY''\)$'" 'N DAY interval pattern'
Assert-Contains $package "'^NUMTOYMINTERVAL\(([1-9][0-9]*),''MONTH''\)$'" 'N MONTH interval pattern'
Assert-Match $package 'IF\s+p_retention_periods\s+IS\s+NULL\s+OR\s+p_retention_periods\s*<\s*0\s+THEN' 'nonnegative retention-periods validation'
Assert-Match $package 'IF\s+p_batch_days\s+IS\s+NULL\s+OR\s+p_batch_days\s*<=\s*0\s+THEN' 'positive full batch-days validation'
Assert-Match $package 'TRUNC\s*\(\s*SYSDATE\s*\)\s*-\s*\(\s*v_interval_count\s*\*\s*p_retention_periods\s*\)' 'N DAY cutoff'
Assert-Match $package "ADD_MONTHS\s*\(\s*TRUNC\s*\(\s*SYSDATE\s*,\s*'MM'\s*\)\s*,\s*-\s*\(\s*v_interval_count\s*\*\s*p_retention_periods\s*\)\s*\)" 'N MONTH cutoff'
Assert-Contains $package "'SELECT CAST(MIN(s.' || v_date_col || ') AS DATE), '" 'full source minimum date'
Assert-Match $package 'WHILE\s+v_batch_start\s*<\s*v_full_end_date\s+LOOP' 'full batch loop'
Assert-Match $package 'v_batch_end\s*:=\s*v_batch_start\s*\+\s*p_batch_days' 'full batch window size'
Assert-Match $package 'execute_insert\(v_sql, v_batch_start, v_batch_end\)' 'full per-window insert'
Assert-Contains $package 'Full batch start/end: ' 'full batch boundary output'
Assert-RegexCount $package '\bFUNCTION\s+[A-Z0-9_$#]+\s*\(' 1 'minimal private function count'
Assert-NotMatch $package '\b(BULK\s+COLLECT|FORALL)\b' 'no row-by-row bulk copy'
Assert-NotContainsInsensitive $package 'p_range_end_date' 'no second full cutoff interface'

$forbiddenPackage = @(
    'CREATE INDEX',
    'CREATE UNIQUE INDEX',
    'user_indexes',
    'user_ind_columns',
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
Assert-Match $schedulerWithoutComments "AT\s+TIME\s+ZONE\s+'Asia/Shanghai'" 'scheduler timezone'
Assert-Match $createJobText 'repeat_interval\s*=>\s*''FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0''' 'scheduler repeat interval'
Assert-Match $createJobText 'enabled\s*=>\s*FALSE' 'scheduler disabled'
Assert-Match $createJobText 'auto_drop\s*=>\s*FALSE' 'scheduler auto_drop false'
Assert-Match $createJobText "start_date\s*=>\s*SYSTIMESTAMP\s+AT\s+TIME\s+ZONE\s+'Asia/Shanghai'" 'scheduler start date timezone'
Assert-Match $jobAction 'c_retention_periods\s+CONSTANT\s+PLS_INTEGER\s*:=\s*1;' 'scheduler retention constant'
Assert-Match $jobAction 'c_batch_days\s+CONSTANT\s+PLS_INTEGER\s*:=\s*1;' 'scheduler batch constant'
Assert-RegexCount $jobAction 'history_archive_pkg\.sync\s*\(' 1 'scheduler sync call count'
Assert-Match $jobAction "p_source_schema\s*=>\s*'ORDERS'" 'scheduler source schema'
Assert-Match $jobAction "p_source_table\s*=>\s*'ORDER_HEADERS'" 'scheduler source table'
Assert-Match $jobAction 'p_retention_periods\s*=>\s*c_retention_periods' 'scheduler retention argument'
Assert-Match $jobAction 'p_batch_days\s*=>\s*c_batch_days' 'scheduler batch argument'
Assert-NotContainsInsensitive $scheduler 'sync_incremental' 'scheduler old call removed'
Assert-NotMatch $jobAction '\bv_(start|end|today)_date\b' 'scheduler date-window variables removed'
Assert-NotMatch $jobAction '\b(FOR|WHILE|LOOP)\b' 'scheduler no loops in action'
Assert-NotMatch $jobAction '\bCOMMIT\b' 'scheduler no commit in action'

Assert-Contains $examples 'history_archive_pkg.sync(' 'sync example'
Assert-Contains $examples 'history_archive_pkg.sync_where(' 'filtered sync example'
Assert-Match $examples 'p_retention_periods\s+=>\s+6' 'sync retention example'
Assert-Match $examples "q'\[AND s\.customer_id = 1001 AND s\.status = 'CLOSED'\]'" 'filtered condition example'
Assert-NotContainsInsensitive $deliveryText 'history_archive_pkg.sync_full' 'old full calls removed from delivery'
Assert-NotContainsInsensitive $deliveryText 'history_archive_pkg.sync_incremental' 'old incremental calls removed from delivery'
Assert-NotContainsInsensitive $examples 'p_retention_days' 'examples old retention name removed'
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
Assert-Contains $readme 'p_retention_periods' 'README retention-period parameter'
Assert-NotContainsInsensitive $readme 'p_retention_days' 'README old retention name removed'
Assert-Contains $readme 'NUMTODSINTERVAL(n, ''DAY'')' 'README N DAY support'
Assert-Contains $readme 'NUMTOYMINTERVAL(n, ''MONTH'')' 'README N MONTH support'
Assert-Contains $readme (Decode-Base64Utf8 '5Zu65a6a5q2j5pW05pWw') 'README fixed positive integer interval N'
Assert-Match $readme 'p_retention_periods\s+=>\s+6' 'README main sync retention-periods example'
Assert-Contains $readme (Decode-Base64Utf8 'YHBfcmV0ZW50aW9uX3BlcmlvZHNgIOihqOekuuS/neeVmeWkmuWwkeS4qua6kOihqOWIhuWMuuWRqOacnw==') 'README retention means source partition periods'
Assert-Contains $readme (Decode-Base64Utf8 'NyDlpKnkuIDkuKrliIbljLrml7bkv53nlZkgNCDkuKrlkajmnJ/nrYnkuo4gMjgg5aSp') 'README seven-day four-period example'
Assert-Contains $readme (Decode-Base64Utf8 'MyDkuKrmnIjkuIDkuKrliIbljLrml7bkv53nlZkgMiDkuKrlkajmnJ/nrYnkuo4gNiDkuKrmnIg=') 'README three-month two-period example'
Assert-Contains $readme (Decode-Base64Utf8 '5pel5YiG5Yy655qE5oiq5pat5pe26Ze05a+56b2Q5Yiw5b2T5aSp6Zu254K5') 'README day cutoff midnight alignment'
Assert-Contains $readme (Decode-Base64Utf8 '5pyI5YiG5Yy655qE5oiq5pat5pe26Ze05a+56b2Q5Yiw6Ieq54S25pyI56ys5LiA5aSp') 'README month cutoff first-day alignment'
Assert-Contains $readme (Decode-Base64Utf8 'LSDlpoLmnpzmupDooajkuI3mmK/lj5fmlK/mjIHnmoTljZXliJcgUkFOR0UgSU5URVJWQUwg5YiG5Yy677yM5Lik56eN5ZCM5q2l6LCD55So5Zyo5Yib5bu65b2S5qGj6KGo5ZKM5aSN5Yi25pWw5o2u5YmN5bCx5Lya5oql6ZSZ44CC') 'README unsupported source partition fails before copy'
Assert-Contains $readme (Decode-Base64Utf8 '5b2S5qGj55uu5qCH6KGo5aeL57uI5L+d5oyB5oyJ5pyIIGBJTlRFUlZBTGAg5YiG5Yy6') 'README target remains monthly interval'
Assert-Match $readme 'p_batch_days\s+=>\s+1' 'README sync batch-days example'
Assert-Contains $readme 'history_archive_pkg.sync(' 'README sync call'
Assert-Contains $readme 'history_archive_pkg.sync_where(' 'README filtered sync call'
Assert-Contains $readme (Decode-Base64Utf8 'YHN5bmNfd2hlcmVgIOeahCBgcF9leHRyYV93aGVyZWAg55Sx5Y+X5L+h5Lu755qE6LCD55So5pa55o+Q5L6b77yM5b+F6aG75LulIGBBTkRgIOW8gOWktOW5tuS9v+eUqOa6kOihqOWIq+WQjSBgc2DjgILplb/luqbkuI3lvpfotoXov4cgNCwwMDAg5a2X6IqC77yb5ouS57ud57uR5a6a5qCH6K6w77yIYDpg77yJ44CB5YiG6ZqU56ym77yIYDtg77yJ44CB5rOo6YeK77yIYC0tYOOAgWAvKmDjgIFgKi9g77yJ44CB5o6n5Yi25a2X56ym44CBRE1ML0RETOOAgeS6i+WKoeOAgVBML1NRTCDlkozmn6Xor6LmlbTlvaLlhbPplK7lrZfvvIhgU0VMRUNUYOOAgWBVTklPTmDjgIFgSU5URVJTRUNUYOOAgWBNSU5VU2DjgIFgV0lUSGDvvInjgII=') 'README sync_where restrictions'
Assert-Contains $readme (Decode-Base64Utf8 '6L+Q6KGM5pe25YC85LiN5pSv5oyBIE9yYWNsZSBxLXF1b3RlZCDlrZfpnaLph4/or63ms5U=') 'README runtime q-quote restriction'
Assert-Contains $readme (Decode-Base64Utf8 '5LiN5b2x5ZON6LCD55So5pa55L2/55SoIFBML1NRTCBxLXF1b3Rpbmcg5p6E6YCg5Y+C5pWw') 'README PL/SQL q-quoting caller allowance'
Assert-Contains $readme (Decode-Base64Utf8 'U2NoZWR1bGVyIOavj+aXpeiwg+eUqCBgc3luY2DvvIzlubbkvb/nlKjlm7rlrprnmoTkv53nlZnlkajmnJ/lkozmibnmrKHorr7nva7jgII=') 'README daily retention scheduler'
Assert-Contains $readme (Decode-Base64Utf8 '6YeN5aSN6LWE5qC855Sx5rqQ56uv5pWw5o2u5o6n5Yi2') 'README source-owned duplicate handling'
Assert-Contains $readme (Decode-Base64Utf8 'LSDkuKTnp43osIPnlKjmr4/mibnmiafooYzliY3pg73kvJrpgJrov4cgYERCTVNfT1VUUFVUYCDovpPlh7rotbfmraLml7bpl7TjgILmn5DkuIDmibnlpLHotKXml7bvvIzor6XmibnkuI3kvJrmj5DkuqTvvIzkvYbmraTliY3lt7Lnu4/miJDlip/mj5DkuqTnmoTmibnmrKHkvJrkv53nlZnvvJvph43ot5HliY3lv4XpobvlhYjkv67mraPmiJbliKDpmaTnm7jlhbPnm67moIfooajorrDlvZXjgII=') 'README cleanup before rerun recovery'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Archive SQL minimal contract failed with $($failures.Count) issue(s)."
}

Write-Output 'PASS: archive SQL minimal contract checks'
