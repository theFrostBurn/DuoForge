function Get-DuoForgeInteractionTestTreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '[]' }
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -Force | Sort-Object FullName)) {
        $entries.Add([ordered]@{ kind = 'directory'; path = [System.IO.Path]::GetRelativePath($resolvedRoot, $directory.FullName) })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force | Sort-Object FullName)) {
        $entries.Add([ordered]@{
            kind = 'file'
            path = [System.IO.Path]::GetRelativePath($resolvedRoot, $file.FullName)
            length = [long]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        })
    }
    return @($entries) | ConvertTo-Json -Depth 10 -Compress
}

function New-DuoForgeInteractionTestKeyReader {
    param([Parameter(Mandatory)][object[]]$Keys)

    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($key in $Keys) { $queue.Enqueue($key) }
    $state = [ordered]@{ reads = 0; remaining = $queue.Count }
    $reader = {
        if ($queue.Count -eq 0) { throw '합성 키 큐가 예상보다 일찍 소진되었습니다.' }
        $state.reads++
        $value = $queue.Dequeue()
        $state.remaining = $queue.Count
        return $value
    }.GetNewClosure()
    return [ordered]@{ reader = $reader; state = $state }
}

function New-DuoForgeInteractionTestLineReader {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($value in $Values) { $queue.Enqueue($value) }
    $state = [ordered]@{ reads = 0; remaining = $queue.Count }
    $reader = {
        param($prompt)
        if ($queue.Count -eq 0) { throw '합성 줄 입력 큐가 예상보다 일찍 소진되었습니다.' }
        $state.reads++
        $value = $queue.Dequeue()
        $state.remaining = $queue.Count
        return $value
    }.GetNewClosure()
    return [ordered]@{ reader = $reader; state = $state }
}

function New-DuoForgeInteractionTestTokenKeys {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Z]+$')][string]$Token)

    $keys = [System.Collections.Generic.List[object]]::new()
    foreach ($character in $Token.ToCharArray()) {
        $consoleKey = [System.Enum]::Parse([ConsoleKey], [string]$character)
        $keys.Add([ConsoleKeyInfo]::new($character, $consoleKey, $true, $false, $false))
    }
    $keys.Add([ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false))
    return @($keys)
}

function New-DuoForgeInteractionTestRun {
    param([Parameter(Mandatory)][string]$Name)

    $input = New-MarkdownFile -Path (Join-Path $tempRoot "$Name\input\brief.md") -Text '# interaction 테스트'
    $workspace = Join-Path $tempRoot "$Name\results"
    $request = New-TestStartRequest -Mode shared-document -Brief $input -Workspace $workspace -DocumentType prd -Name $Name
    $validation = Test-DuoForgeStartRequest -Request $request -DoctorReport (New-FakeDoctor) -Config (New-TestConfig -ResultsRoot $workspace)
    $run = New-DuoForgeRun -ValidationResult $validation
    $null = & $module { param($directory) Initialize-DuoForgeStageGraph -RunDirectory $directory } $run.runDirectory
    $loadedRun = & $module { param($runId, $resultsRoot) Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $resultsRoot } $run.runId $workspace
    return [ordered]@{ run = $loadedRun; workspace = $workspace }
}

function Get-DuoForgeInteractionAbortCases {
    return @(
        [ordered]@{ name = 'Esc'; expectedAction = 'back'; expectedReads = 1; expectedExplanationTarget = 'parent'; keys = @([ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)) }
        [ordered]@{ name = 'B'; expectedAction = 'back'; expectedReads = 1; expectedExplanationTarget = 'parent'; keys = @([ConsoleKeyInfo]::new('b', [ConsoleKey]::B, $false, $false, $false)) }
        [ordered]@{ name = 'Q'; expectedAction = 'cancel'; expectedReads = 1; expectedExplanationTarget = 'work-menu'; keys = @([ConsoleKeyInfo]::new('q', [ConsoleKey]::Q, $false, $false, $false)) }
        [ordered]@{ name = 'Ctrl+C'; expectedAction = 'interrupt'; expectedReads = 1; expectedExplanationTarget = 'work-menu'; keys = @([ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)) }
        [ordered]@{ name = '오타'; expectedAction = 'back'; expectedReads = 6; expectedExplanationTarget = 'parent'; keys = @(
            [ConsoleKeyInfo]::new('L', [ConsoleKey]::L, $true, $false, $false)
            [ConsoleKeyInfo]::new('I', [ConsoleKey]::I, $true, $false, $false)
            [ConsoleKeyInfo]::new('F', [ConsoleKey]::F, $true, $false, $false)
            [ConsoleKeyInfo]::new('E', [ConsoleKey]::E, $true, $false, $false)
            [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false)
            [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)
        ) }
        [ordered]@{ name = '버퍼 중 B'; expectedAction = 'back'; expectedReads = 4; expectedExplanationTarget = 'parent'; keys = @(
            [ConsoleKeyInfo]::new('L', [ConsoleKey]::L, $true, $false, $false)
            [ConsoleKeyInfo]::new('b', [ConsoleKey]::B, $false, $false, $false)
            [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false)
            [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)
        ) }
    )
}

function Get-DuoForgeYesNoInteractionCases {
    return @(
        [ordered]@{ name = 'Esc'; expectedAction = 'back'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)) }
        [ordered]@{ name = 'B'; expectedAction = 'back'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new('b', [ConsoleKey]::B, $false, $false, $false)) }
        [ordered]@{ name = 'Q'; expectedAction = 'cancel'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new('q', [ConsoleKey]::Q, $false, $false, $false)) }
        [ordered]@{ name = 'N'; expectedAction = 'cancel'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new('n', [ConsoleKey]::N, $false, $false, $false)) }
        [ordered]@{ name = '기본 Enter'; expectedAction = 'cancel'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false)) }
        [ordered]@{ name = 'Ctrl+C'; expectedAction = 'interrupt'; expectedReads = 1; keys = @([ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)) }
        [ordered]@{ name = '오타'; expectedAction = 'back'; expectedReads = 2; keys = @(
            [ConsoleKeyInfo]::new('x', [ConsoleKey]::X, $false, $false, $false)
            [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)
        ) }
    )
}

Test-Case '새 작업과 추가 자료 Y/N의 Esc/B/Q/N/Ctrl+C/오타는 올바르게 복귀하고 mutation을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'yes-no-boundary-abort'
    $validation = [ordered]@{ valid = $true; request = [ordered]@{}; errors = @() }
    foreach ($case in @(Get-DuoForgeYesNoInteractionCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ run = 0; evidence = 0; frames = [System.Collections.Generic.List[string]]::new() }
        $interactiveReader = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $cliReader = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $evidenceReader = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $results = & $module {
            param($validationValue, $runValue, $state, $firstReader, $secondReader, $thirdReader)
            $runInvoker = { param($validated) $state.run++; throw 'Y가 아닌 경로에서 run을 만들면 안 됩니다.' }.GetNewClosure()
            $evidenceInvoker = { param($runId, $issueId, $file, $resultsRoot) $state.evidence++; throw 'Y가 아닌 경로에서 자료를 연결하면 안 됩니다.' }.GetNewClosure()
            $frameWriter = { param($lines) $state.frames.Add(($lines -join "`n")) }.GetNewClosure()
            return [ordered]@{
                interactive = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -RunInvoker $runInvoker -ConfirmationKeyReader $firstReader -ConfirmationFrameWriter $frameWriter -ConfirmationCapabilityProbe { $true }
                cli = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -RunInvoker $runInvoker -ConfirmationKeyReader $secondReader -ConfirmationFrameWriter $frameWriter -ConfirmationCapabilityProbe { $true }
                evidence = Invoke-DuoForgeEvidenceBoundaryInternal -Run $runValue -IssueId 'D-001' -File 'synthetic-evidence.md' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -EvidenceInvoker $evidenceInvoker -ConfirmationKeyReader $thirdReader -ConfirmationFrameWriter $frameWriter -ConfirmationCapabilityProbe { $true }
            }
        } $validation $fixture.run $control $interactiveReader.reader $cliReader.reader $evidenceReader.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $interactiveTarget = if ($case.expectedAction -eq 'back') { 'parent' } else { 'home' }
        $evidenceTarget = if ($case.expectedAction -eq 'back') { 'parent' } else { 'work-menu' }
        Assert-Equal $results.interactive.interaction.action $case.expectedAction "새 작업/$($case.name)의 action이 다릅니다."
        Assert-Equal $results.interactive.interaction.returnTarget $interactiveTarget "새 작업/$($case.name)의 복귀 위치가 다릅니다."
        Assert-Equal $results.cli.interaction.action $case.expectedAction "CLI 새 작업/$($case.name)의 action이 다릅니다."
        Assert-Equal $results.cli.interaction.returnTarget 'shell' "CLI 새 작업/$($case.name)의 복귀 위치가 다릅니다."
        Assert-Equal $results.evidence.interaction.action $case.expectedAction "추가 자료/$($case.name)의 action이 다릅니다."
        Assert-Equal $results.evidence.interaction.returnTarget $evidenceTarget "추가 자료/$($case.name)의 복귀 위치가 다릅니다."
        Assert-Equal $control.run 0 "$($case.name)에서 run invoker가 호출되었습니다."
        Assert-Equal $control.evidence 0 "$($case.name)에서 evidence invoker가 호출되었습니다."
        foreach ($readerState in @($interactiveReader.state, $cliReader.state, $evidenceReader.state)) {
            Assert-Equal $readerState.reads $case.expectedReads "$($case.name)의 합성 키 소비 수가 다릅니다."
            Assert-Equal $readerState.remaining 0 "$($case.name)의 합성 키가 남았습니다."
        }
        if ($case.name -eq '오타') { Assert-ContainsText ($control.frames -join "`n---`n") 'Y 또는 N' 'Y/N 오타 경고가 같은 화면에 남지 않았습니다.' }
        Assert-Equal $after $before "$($case.name)에서 run 생성·파일 복사·자료 연결·답변 기록·단계 reset이 발생했습니다."
    }
}

Test-Case '새 작업과 추가 자료 Y/N 줄 폴백은 B/Q/N/Ctrl+C/오타와 ReturnTarget을 보존한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'yes-no-boundary-line'
    $validation = [ordered]@{ valid = $true; request = [ordered]@{}; errors = @() }
    $cases = @(
        [ordered]@{ name = 'back'; values = @('b'); action = 'back' }
        [ordered]@{ name = 'cancel'; values = @('q'); action = 'cancel' }
        [ordered]@{ name = 'no'; values = @('n'); action = 'cancel' }
        [ordered]@{ name = 'interrupt'; values = @('ctrl+c'); action = 'interrupt' }
        [ordered]@{ name = 'invalid-then-back'; values = @('maybe', 'b'); action = 'back' }
    )
    foreach ($case in $cases) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ run = 0; evidence = 0 }
        $interactiveInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
        $cliInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
        $evidenceInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
        $results = & $module {
            param($validationValue, $runValue, $state, $firstReader, $secondReader, $thirdReader)
            $runInvoker = { param($validated) $state.run++; throw '줄 이탈 경로에서 run을 만들면 안 됩니다.' }.GetNewClosure()
            $evidenceInvoker = { param($runId, $issueId, $file, $resultsRoot) $state.evidence++; throw '줄 이탈 경로에서 자료를 연결하면 안 됩니다.' }.GetNewClosure()
            return [ordered]@{
                interactive = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -InputReader $firstReader -RunInvoker $runInvoker 6>$null
                cli = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $secondReader -RunInvoker $runInvoker 6>$null
                evidence = Invoke-DuoForgeEvidenceBoundaryInternal -Run $runValue -IssueId 'D-001' -File 'synthetic-evidence.md' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $thirdReader -EvidenceInvoker $evidenceInvoker 6>$null
            }
        } $validation $fixture.run $control $interactiveInput.reader $cliInput.reader $evidenceInput.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $results.interactive.interaction.action $case.action
        Assert-Equal $results.interactive.interaction.returnTarget $(if ($case.action -eq 'back') { 'parent' } else { 'home' })
        Assert-Equal $results.cli.interaction.action $case.action
        Assert-Equal $results.cli.interaction.returnTarget 'shell'
        Assert-Equal $results.evidence.interaction.action $case.action
        Assert-Equal $results.evidence.interaction.returnTarget $(if ($case.action -eq 'back') { 'parent' } else { 'work-menu' })
        Assert-Equal $control.run 0
        Assert-Equal $control.evidence 0
        foreach ($readerState in @($interactiveInput.state, $cliInput.state, $evidenceInput.state)) { Assert-Equal $readerState.remaining 0 }
        Assert-Equal $after $before "$($case.name) 줄 폴백에서 영구 상태가 변경되었습니다."
    }
}

Test-Case '새 작업과 추가 자료 Y/N 리디렉션은 mutation 없이 unavailable로 즉시 돌아간다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'yes-no-boundary-unavailable'
    $validation = [ordered]@{ valid = $true; request = [ordered]@{}; errors = @() }
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $control = [ordered]@{ run = 0; evidence = 0 }
    $results = & $module {
        param($validationValue, $runValue, $state)
        $runInvoker = { param($validated) $state.run++; throw 'unavailable에서 run을 만들면 안 됩니다.' }.GetNewClosure()
        $evidenceInvoker = { param($runId, $issueId, $file, $resultsRoot) $state.evidence++; throw 'unavailable에서 자료를 연결하면 안 됩니다.' }.GetNewClosure()
        $redirected = { [ordered]@{ cursor = $false; reason = 'redirected' } }
        return [ordered]@{
            interactive = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -RunInvoker $runInvoker -ConfirmationCapabilityProbe $redirected 6>$null
            cli = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -RunInvoker $runInvoker -ConfirmationCapabilityProbe $redirected 6>$null
            evidence = Invoke-DuoForgeEvidenceBoundaryInternal -Run $runValue -IssueId 'D-001' -File 'synthetic-evidence.md' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -EvidenceInvoker $evidenceInvoker -ConfirmationCapabilityProbe $redirected 6>$null
        }
    } $validation $fixture.run $control
    $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    Assert-Equal $results.interactive.interaction.action 'unavailable'
    Assert-Equal $results.interactive.interaction.returnTarget 'home'
    Assert-Equal $results.cli.interaction.action 'unavailable'
    Assert-Equal $results.cli.interaction.returnTarget 'shell'
    Assert-Equal $results.evidence.interaction.action 'unavailable'
    Assert-Equal $results.evidence.interaction.returnTarget 'work-menu'
    Assert-Equal $control.run 0
    Assert-Equal $control.evidence 0
    Assert-Equal $after $before 'Y/N unavailable에서 영구 상태가 변경되었습니다.'
}

Test-Case 'Y 선택만 새 작업과 추가 자료의 주입 invoker를 각각 한 번 호출한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'yes-no-boundary-submit'
    $validation = [ordered]@{ valid = $true; request = [ordered]@{}; errors = @() }
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $control = [ordered]@{ run = 0; evidence = 0 }
    $interactiveReader = New-DuoForgeInteractionTestKeyReader -Keys @([ConsoleKeyInfo]::new('y', [ConsoleKey]::Y, $false, $false, $false))
    $cliReader = New-DuoForgeInteractionTestKeyReader -Keys @([ConsoleKeyInfo]::new('y', [ConsoleKey]::Y, $false, $false, $false))
    $evidenceReader = New-DuoForgeInteractionTestKeyReader -Keys @([ConsoleKeyInfo]::new('y', [ConsoleKey]::Y, $false, $false, $false))
    $results = & $module {
        param($validationValue, $runValue, $state, $firstReader, $secondReader, $thirdReader)
        $runInvoker = { param($validated) $state.run++; return [ordered]@{ runId = 'synthetic-run'; runDirectory = 'synthetic-directory' } }.GetNewClosure()
        $evidenceInvoker = { param($runId, $issueId, $file, $resultsRoot) $state.evidence++; return [ordered]@{ resetSteps = @() } }.GetNewClosure()
        return [ordered]@{
            interactive = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -RunInvoker $runInvoker -ConfirmationKeyReader $firstReader -ConfirmationFrameWriter { param($lines) } -ConfirmationCapabilityProbe { $true }
            cli = Invoke-DuoForgeRunCreationBoundaryInternal -Validation $validationValue -ReturnTarget shell -CancelReturnTarget shell -RunInvoker $runInvoker -ConfirmationKeyReader $secondReader -ConfirmationFrameWriter { param($lines) } -ConfirmationCapabilityProbe { $true }
            evidence = Invoke-DuoForgeEvidenceBoundaryInternal -Run $runValue -IssueId 'D-001' -File 'synthetic-evidence.md' -EvidenceInvoker $evidenceInvoker -ConfirmationKeyReader $thirdReader -ConfirmationFrameWriter { param($lines) } -ConfirmationCapabilityProbe { $true }
        }
    } $validation $fixture.run $control $interactiveReader.reader $cliReader.reader $evidenceReader.reader
    $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    Assert-Equal $results.interactive.interaction.action 'submit'
    Assert-Equal $results.cli.interaction.action 'submit'
    Assert-Equal $results.evidence.interaction.action 'submit'
    Assert-Equal $control.run 2
    Assert-Equal $control.evidence 1
    foreach ($readerState in @($interactiveReader.state, $cliReader.state, $evidenceReader.state)) { Assert-Equal $readerState.remaining 0 }
    Assert-Equal $after $before '주입한 Y 성공 경계에서 실제 run 파일이나 단계 상태가 변경되었습니다.'
}

Test-Case '질문 계층 메뉴는 Esc/B/Q/Ctrl+C와 0 오타를 구조화하고 mutation을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'question-menu-boundary'
    $items = @(
        [ordered]@{ value = 'answer:A'; label = '1안'; shortcuts = @('1'); enabled = $true }
        [ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
    )
    $cases = @(
        [ordered]@{ name = 'Esc'; action = 'back'; target = 'parent'; keys = @([ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false)) }
        [ordered]@{ name = 'B'; action = 'back'; target = 'parent'; keys = @([ConsoleKeyInfo]::new('b', [ConsoleKey]::B, $false, $false, $false)) }
        [ordered]@{ name = 'Q'; action = 'cancel'; target = 'work-menu'; keys = @([ConsoleKeyInfo]::new('q', [ConsoleKey]::Q, $false, $false, $false)) }
        [ordered]@{ name = 'Ctrl+C'; action = 'interrupt'; target = 'work-menu'; keys = @([ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)) }
        [ordered]@{ name = '0 오타'; action = 'back'; target = 'parent'; keys = @(
            [ConsoleKeyInfo]::new('0', [ConsoleKey]::D0, $false, $false, $false)
            [ConsoleKeyInfo]::new('b', [ConsoleKey]::B, $false, $false, $false)
        ) }
    )
    foreach ($case in $cases) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $frames = [System.Collections.Generic.List[string]]::new()
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $interaction = & $module {
            param($menuItems, $reader, $frameList)
            $writer = { param($lines) $frameList.Add(($lines -join "`n")) }.GetNewClosure()
            Invoke-DuoForgeMenuInteractionInternal -Items $menuItems -Title '질문 결정' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -KeyReader $reader -FrameWriter $writer -CapabilityProbe { $true }
        } $items $keyInput.reader $frames
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $interaction.action $case.action "$($case.name)의 질문 메뉴 action이 다릅니다."
        Assert-Equal $interaction.returnTarget $case.target "$($case.name)의 질문 메뉴 복귀 위치가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0
        if ($case.name -eq '0 오타') { Assert-ContainsText ($frames -join "`n") '현재 가능한 항목' '0이 이전으로 처리되지 않고 오타 안내를 남겨야 합니다.' }
        Assert-Equal $after $before "$($case.name)의 질문 메뉴에서 답변·파일·단계 상태가 변경되었습니다."
    }

    foreach ($case in @(
        [ordered]@{ values = @('b'); action = 'back'; target = 'parent' }
        [ordered]@{ values = @('q'); action = 'cancel'; target = 'work-menu' }
        [ordered]@{ values = @('ctrl+c'); action = 'interrupt'; target = 'work-menu' }
        [ordered]@{ values = @('0', 'b'); action = 'back'; target = 'parent' }
    )) {
        $lineInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
        $interaction = & $module { param($menuItems, $reader) Invoke-DuoForgeMenuInteractionInternal -Items $menuItems -Title '질문 결정' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $reader 6>$null } $items $lineInput.reader
        Assert-Equal $interaction.action $case.action
        Assert-Equal $interaction.returnTarget $case.target
        Assert-Equal $lineInput.state.remaining 0
    }
    $unavailable = & $module { param($menuItems) Invoke-DuoForgeMenuInteractionInternal -Items $menuItems -Title '질문 결정' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -CapabilityProbe { [ordered]@{ cursor = $false; reason = 'redirected' } } 6>$null } $items
    Assert-Equal $unavailable.action 'unavailable'
    Assert-Equal $unavailable.returnTarget 'work-menu'
}

Test-Case '자유 입력은 raw 편집기 없이 B/Q와 Unicode를 제출 데이터로 보존한다' {
    foreach ($value in @('B', 'Q', '한글 붙여넣기 é 😀')) {
        $lineInput = New-DuoForgeInteractionTestLineReader -Values @($value)
        $interaction = & $module { param($reader) Read-DuoForgeFreeTextInteractionInternal -Prompt '자유 입력' -ReturnTarget parent -InterruptReturnTarget work-menu -InputReader $reader } $lineInput.reader
        Assert-Equal $interaction.action 'submit'
        Assert-Equal $interaction.value $value
        Assert-Equal $interaction.source 'line'
        Assert-Equal $lineInput.state.remaining 0
    }

    $selectionOptions = [ordered]@{ displayName = '합성 AI'; catalogSource = 'synthetic'; suggestedModels = @([ordered]@{ value = 'known-model'; displayName = 'known-model'; recommended = $true; description = '합성' }) }
    foreach ($value in @('B', 'Q')) {
        $model = & $module { param($options, $text) Read-DuoForgeModelChoiceInternal -Provider codex -SelectionOptions $options -MenuInvoker { [ordered]@{ action = 'submit'; value = 'custom'; source = 'line'; returnTarget = 'parent' } } -InputReader { param($prompt) $text }.GetNewClosure() 6>$null } $selectionOptions $value
        Assert-Equal $model $value "모델 자유 입력 $value가 탐색키로 가로채졌습니다."
    }
}

Test-Case 'Windows 선택기는 취소와 실행 실패를 분리하고 최근 경로를 실패 시 기록하지 않는다' {
    $selectedFile = New-MarkdownFile -Path (Join-Path $tempRoot 'dialog-boundary\selected.md') -Text '# 선택 파일'
    $results = & $module {
        param($file)
        [ordered]@{
            cancel = Select-DuoForgeWindowsPath -Type File -HostProbe { $true } -DialogInvoker { [ordered]@{ result = 'Cancel'; path = '' } }
            submit = Select-DuoForgeWindowsPath -Type File -HostProbe { $true } -DialogInvoker { [ordered]@{ result = 'OK'; path = $file } }.GetNewClosure()
            failed = Select-DuoForgeWindowsPath -Type File -HostProbe { $true } -DialogInvoker { throw 'synthetic-dialog-failure' }
            unavailable = Select-DuoForgeWindowsPath -Type File -HostProbe { $false } -DialogInvoker { throw '호출되면 안 됩니다.' }
        }
    } $selectedFile
    Assert-Equal $results.cancel.action 'back'
    Assert-Equal $results.cancel.source 'dialog'
    Assert-Equal $results.submit.action 'submit'
    Assert-Equal $results.submit.value $selectedFile
    Assert-Equal $results.failed.action 'unavailable'
    Assert-Equal $results.failed.reason 'launch-failed'
    Assert-Equal $results.unavailable.action 'unavailable'
    Assert-Equal $results.unavailable.reason 'non-interactive'

    $control = [ordered]@{ recent = 0 }
    $menuQueue = [System.Collections.Generic.Queue[string]]::new()
    $menuQueue.Enqueue('1')
    $menuQueue.Enqueue('B')
    $menuInvoker = {
        param($items, $title, $initial, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $value = $menuQueue.Dequeue()
        if ($value -eq 'B') { return [ordered]@{ action = 'back'; value = $null; source = 'line'; returnTarget = $returnTarget } }
        return [ordered]@{ action = 'submit'; value = $value; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $recentWriter = { param($path, $role) $control.recent++ }.GetNewClosure()
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $cancelled = & $module { param($menu, $writer) Read-DuoForgePathChoice -Prompt '경로' -Role 'test' -MenuInvoker $menu -PathPicker { [ordered]@{ action = 'back'; value = $null; source = 'dialog'; returnTarget = 'parent' } } -RecentPathWriter $writer 6>$null } $menuInvoker $recentWriter
    $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    Assert-Equal $cancelled $null
    Assert-Equal $control.recent 0
    Assert-Equal $after $before '선택창 취소에서 최근 경로나 파일 상태가 변경되었습니다.'

    $submitControl = [ordered]@{ recent = 0; path = '' }
    $submitMenu = { param($items, $title, $initial, $returnTarget) [ordered]@{ action = 'submit'; value = '1'; source = 'line'; returnTarget = $returnTarget } }
    $submitWriter = { param($path, $role) $submitControl.recent++; $submitControl.path = $path }.GetNewClosure()
    $resolved = & $module { param($file, $menu, $writer) Read-DuoForgePathChoice -Prompt '경로' -Role 'test' -MenuInvoker $menu -PathPicker { param($type, $title) [ordered]@{ action = 'submit'; value = $file; source = 'dialog'; returnTarget = 'parent' } }.GetNewClosure() -RecentPathWriter $writer 6>$null } $selectedFile $submitMenu $submitWriter
    Assert-Equal $resolved ([System.IO.Path]::GetFullPath($selectedFile))
    Assert-Equal $submitControl.recent 1
    Assert-Equal $submitControl.path ([System.IO.Path]::GetFullPath($selectedFile))
}

Test-Case '진행 개요와 완료 경계는 Esc/Q/Ctrl+C/Enter를 안전하게 분리한다' {
    $pause = [ordered]@{ calls = 0 }
    foreach ($case in @(
        [ordered]@{ name = 'Esc'; key = [ConsoleKeyInfo]::new([char]27, [ConsoleKey]::Escape, $false, $false, $false); completion = 'back' }
        [ordered]@{ name = 'Q'; key = [ConsoleKeyInfo]::new('q', [ConsoleKey]::Q, $false, $false, $false); completion = 'cancel' }
        [ordered]@{ name = 'Ctrl+C'; key = [ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true); completion = 'interrupt' }
        [ordered]@{ name = 'Enter'; key = [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false); completion = 'submit' }
    )) {
        $view = [ordered]@{ mode = 'fullscreen'; screenMode = 'overview'; selectedCommittedIndex = -1; recentCommittedCount = 0; detailScrollOffset = 0; pauseRequestStatus = ''; returnTarget = 'work-menu'; controlNotice = '' }
        $requester = { $pause.calls++; throw 'P 외 입력에서 pause를 요청하면 안 됩니다.' }.GetNewClosure()
        & $module { param($viewValue, $keyValue, $request) Invoke-DuoForgeProgressControlInputInternal -View $viewValue -KeyReader { $keyValue }.GetNewClosure() -PauseRequester $request } $view $case.key $requester
        Assert-Equal $pause.calls 0 "$($case.name)에서 pause를 요청했습니다."
        if ($case.name -eq 'Ctrl+C') {
            Assert-Equal $view.lastInteraction.action 'interrupt'
            Assert-Equal $view.lastInteraction.returnTarget 'work-menu'
        }
        else { Assert-ContainsText $view.controlNotice 'AI 작업은 계속됩니다' "$($case.name)의 안전 안내가 없습니다." }

        $completion = & $module { param($keyValue) Read-DuoForgeProgressCompletionInteractionInternal -ReturnTarget work-menu -KeyReader { $keyValue }.GetNewClosure() } $case.key
        Assert-Equal $completion.action $case.completion
        Assert-Equal $completion.returnTarget 'work-menu'
    }
}

Test-Case 'PARTIAL 확인의 Esc/B/Q/Ctrl+C/오타는 재검증과 영구 변경을 만들지 않는다' {
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ revalidation = 0 }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $validation = [ordered]@{
            valid = $false
            request = [ordered]@{ allowPartial = $false }
            doctor = [ordered]@{}
            errors = @([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = '합성 부분 분석 확인' })
        }
        $result = & $module {
            param($validationValue, $state, $keyReader)
            $validationInvoker = {
                param($request, $doctor)
                $state.revalidation++
                throw '이탈 경로에서 재검증하면 안 됩니다.'
            }.GetNewClosure()
            Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -ValidationInvoker $validationInvoker -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        } $validation $control $keyInput.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $expectedTarget = if ($case.expectedAction -eq 'back') { 'parent' } else { 'home' }
        Assert-Equal $result.interaction.action $case.expectedAction "$($case.name)의 PARTIAL action이 다릅니다."
        Assert-Equal $result.interaction.returnTarget $expectedTarget "$($case.name)의 PARTIAL 복귀 위치가 다릅니다."
        Assert-False ([bool]$result.validation.request.allowPartial) "$($case.name)에서 부분 분석 동의가 기록되었습니다."
        Assert-Equal $control.revalidation 0 "$($case.name)에서 요청 재검증이 호출되었습니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "$($case.name)의 PARTIAL 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0
        Assert-Equal $after $before "$($case.name)에서 run·파일·답변·단계 상태가 변경되었습니다."
    }

    $unavailableControl = [ordered]@{ revalidation = 0; input = 0 }
    $unavailableValidation = [ordered]@{
        valid = $false
        request = [ordered]@{ allowPartial = $false }
        doctor = [ordered]@{}
        errors = @([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = '합성 부분 분석 확인' })
    }
    $beforeUnavailable = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $unavailable = & $module {
        param($validationValue, $state)
        $validationInvoker = { param($request, $doctor) $state.revalidation++; throw '무입력 경로에서 재검증하면 안 됩니다.' }.GetNewClosure()
        Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validationValue -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -ValidationInvoker $validationInvoker -ConfirmationCapabilityProbe { [ordered]@{ cursor = $false; reason = 'redirected' } } 6>$null
    } $unavailableValidation $unavailableControl
    $afterUnavailable = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    Assert-Equal $unavailable.interaction.action 'unavailable'
    Assert-Equal $unavailable.interaction.returnTarget 'home'
    Assert-False ([bool]$unavailable.validation.request.allowPartial)
    Assert-Equal $unavailableControl.revalidation 0
    Assert-Equal $afterUnavailable $beforeUnavailable 'PARTIAL unavailable 경로에서 영구 상태가 변경되었습니다.'
}

Test-Case 'ROUND 확인의 Esc/B/Q/Ctrl+C/오타는 라운드 추가와 영구 변경을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'round-abort'
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ round = 0 }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $interaction = & $module {
            param($runValue, $state, $keyReader)
            $roundInvoker = {
                param($runId, $resultsRoot)
                $state.round++
                throw '이탈 경로에서 라운드를 추가하면 안 됩니다.'
            }.GetNewClosure()
            Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $runValue -RoundInvoker $roundInvoker -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        } $fixture.run $control $keyInput.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $expectedTarget = if ($case.expectedAction -eq 'back') { 'parent' } else { 'work-menu' }
        Assert-Equal $interaction.action $case.expectedAction "$($case.name)의 ROUND action이 다릅니다."
        Assert-Equal $interaction.returnTarget $expectedTarget "$($case.name)의 ROUND 복귀 위치가 다릅니다."
        Assert-Equal $control.round 0 "$($case.name)에서 라운드 invoker가 호출되었습니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "$($case.name)의 ROUND 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0
        Assert-Equal $after $before "$($case.name)에서 라운드·파일·답변·단계 상태가 변경되었습니다."
    }
}

Test-Case '두 APPLY 확인의 Esc/B/Q/Ctrl+C/오타는 답변·제약 기록과 단계 reset을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'apply-abort'
    foreach ($boundary in @('answer', 'common')) {
        foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
            $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
            $control = [ordered]@{ decision = 0; constraint = 0 }
            $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
            $interaction = & $module {
                param($runValue, $boundaryValue, $state, $keyReader)
                $decisionInvoker = {
                    param($runId, $issueId, $text, $resultsRoot, $replacePrevious)
                    $state.decision++
                    throw '이탈 경로에서 답변을 기록하면 안 됩니다.'
                }.GetNewClosure()
                $constraintInvoker = {
                    param($runId, $issueId, $text, $resultsRoot)
                    $state.constraint++
                    throw '이탈 경로에서 제약을 기록하면 안 됩니다.'
                }.GetNewClosure()
                Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary $boundaryValue -Run $runValue -IssueId 'D-001' -Text 'B' -DecisionInvoker $decisionInvoker -ConstraintInvoker $constraintInvoker -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
            } $fixture.run $boundary $control $keyInput.reader
            $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
            $expectedTarget = if ($case.expectedAction -eq 'back') { 'parent' } else { 'work-menu' }
            Assert-Equal $interaction.action $case.expectedAction "$boundary/$($case.name)의 APPLY action이 다릅니다."
            Assert-Equal $interaction.returnTarget $expectedTarget "$boundary/$($case.name)의 APPLY 복귀 위치가 다릅니다."
            Assert-Equal $control.decision 0 "$boundary/$($case.name)에서 답변 invoker가 호출되었습니다."
            Assert-Equal $control.constraint 0 "$boundary/$($case.name)에서 제약 invoker가 호출되었습니다."
            Assert-Equal $keyInput.state.reads $case.expectedReads "$boundary/$($case.name)의 APPLY 합성 키 소비 수가 다릅니다."
            Assert-Equal $keyInput.state.remaining 0
            Assert-Equal $after $before "$boundary/$($case.name)에서 답변·제약·파일·단계 상태가 변경되었습니다."
        }
    }
}

Test-Case 'CLI DEFER 확인의 Esc/B/Q/Ctrl+C/오타는 interaction 출력, 답변 기록과 영구 변경을 만들지 않는다' {
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ decision = 0 }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $output = @(& $module {
            param($state, $keyReader, $workspace)
            $decisionInvoker = {
                param($runId, $issueId, $action, $resultsRoot, $confirmPartial)
                $state.decision++
                throw '이탈 경로에서 보류 답변을 기록하면 안 됩니다.'
            }.GetNewClosure()
            Invoke-DuoForgeCliCoreInternal -Arguments @('defer', '--run', 'synthetic-run', '--issue', 'D-001', '--workspace', $workspace) -DecisionInvoker $decisionInvoker -InteractiveHostProbe { $true } -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        } $control $keyInput.reader $tempRoot)
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $interactions = @($output | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('action') })
        Assert-Equal $interactions.Count 0 "$($case.name)의 DEFER 취소 interaction이 성공 출력에 노출되었습니다."
        Assert-Equal $control.decision 0 "$($case.name)에서 보류 답변 invoker가 호출되었습니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "$($case.name)의 DEFER 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0
        Assert-Equal $after $before "$($case.name)에서 보류·파일·답변·단계 상태가 변경되었습니다."
    }
}

Test-Case '정확한 PARTIAL/ROUND/APPLY/DEFER만 각 주입 invoker를 한 번 호출하고 자유 입력 B/Q를 보존한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'exact-boundary-submit'
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $control = [ordered]@{
        partial = 0
        round = 0
        decision = 0
        constraint = 0
        defer = 0
        allowPartial = $false
        texts = [System.Collections.Generic.List[string]]::new()
    }
    $partialKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'PARTIAL')
    $roundKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'ROUND')
    $answerKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'APPLY')
    $commonKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'APPLY')
    $deferKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'DEFER')
    $result = & $module {
        param($runValue, $state, $partialReader, $roundReader, $answerReader, $commonReader, $deferReader, $workspace)
        $validation = [ordered]@{
            valid = $false
            request = [ordered]@{ allowPartial = $false }
            doctor = [ordered]@{}
            errors = @([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = '합성 부분 분석 확인' })
        }
        $validationInvoker = {
            param($request, $doctor)
            $state.partial++
            $state.allowPartial = [bool]$request.allowPartial
            return [ordered]@{ valid = $true; request = $request; doctor = $doctor; errors = @() }
        }.GetNewClosure()
        $roundInvoker = { param($runId, $resultsRoot) $state.round++; return [ordered]@{ addedSteps = 1 } }.GetNewClosure()
        $decisionInvoker = {
            param($runId, $issueId, $text, $resultsRoot, $replacePrevious)
            $state.decision++
            $state.texts.Add([string]$text)
            return [ordered]@{ resetSteps = @() }
        }.GetNewClosure()
        $constraintInvoker = {
            param($runId, $issueId, $text, $resultsRoot)
            $state.constraint++
            $state.texts.Add([string]$text)
            return [ordered]@{ resetSteps = @() }
        }.GetNewClosure()
        $deferInvoker = {
            param($runId, $issueId, $action, $resultsRoot, $confirmPartial)
            $state.defer++
            return [ordered]@{ status = 'SYNTHETIC'; action = $action }
        }.GetNewClosure()
        $partial = Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -ValidationInvoker $validationInvoker -ConfirmationKeyReader $partialReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        $round = Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $runValue -RoundInvoker $roundInvoker -ConfirmationKeyReader $roundReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        $answer = Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary answer -Run $runValue -IssueId 'D-001' -Text 'B' -DecisionInvoker $decisionInvoker -ConstraintInvoker $constraintInvoker -ConfirmationKeyReader $answerReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        $common = Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary common -Run $runValue -IssueId 'D-001' -Text 'Q' -DecisionInvoker $decisionInvoker -ConstraintInvoker $constraintInvoker -ConfirmationKeyReader $commonReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        (& { Invoke-DuoForgeCliCoreInternal -Arguments @('defer', '--run', 'synthetic-run', '--issue', 'D-001', '--workspace', $workspace) -DecisionInvoker $deferInvoker -InteractiveHostProbe { $true } -ConfirmationKeyReader $deferReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } } 6>&1 | Out-String) | Out-Null
        return [ordered]@{ partial = $partial.interaction; round = $round; answer = $answer; common = $common }
    } $fixture.run $control $partialKeys.reader $roundKeys.reader $answerKeys.reader $commonKeys.reader $deferKeys.reader $tempRoot
    $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    foreach ($name in @('partial', 'round', 'answer', 'common')) { Assert-Equal $result[$name].action 'submit' "$name 정확 확인이 submit이 아닙니다." }
    Assert-Equal $control.partial 1
    Assert-True ([bool]$control.allowPartial)
    Assert-Equal $control.round 1
    Assert-Equal $control.decision 1
    Assert-Equal $control.constraint 1
    Assert-Equal $control.defer 1
    Assert-Equal $control.texts[0] 'B' '자유 입력 B가 답변 데이터로 보존되지 않았습니다.'
    Assert-Equal $control.texts[1] 'Q' '자유 입력 Q가 공통 전제 데이터로 보존되지 않았습니다.'
    foreach ($readerState in @($partialKeys.state, $roundKeys.state, $answerKeys.state, $commonKeys.state, $deferKeys.state)) { Assert-Equal $readerState.remaining 0 }
    Assert-Equal $after $before '주입 성공 경계에서 실제 run 파일이나 단계 상태가 변경되었습니다.'
}

Test-Case 'PARTIAL/ROUND/APPLY/DEFER 줄 입력 폴백은 ReturnTarget과 mutation 0건을 보존한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'exact-boundary-line-abort'
    $lineCases = @(
        [ordered]@{ name = 'back'; values = @('b'); action = 'back' }
        [ordered]@{ name = 'cancel'; values = @('q'); action = 'cancel' }
        [ordered]@{ name = 'interrupt'; values = @('ctrl+c'); action = 'interrupt' }
        [ordered]@{ name = 'invalid-then-back'; values = @('LIFE', 'b'); action = 'back' }
    )
    foreach ($boundary in @('partial', 'round', 'apply', 'defer')) {
        foreach ($case in $lineCases) {
            $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
            $control = [ordered]@{ calls = 0 }
            $lineInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
            $interaction = & $module {
                param($runValue, $boundaryValue, $state, $reader, $workspace)
                $mutationInvoker = { $state.calls++; throw '줄 이탈 경로에서 mutation을 호출하면 안 됩니다.' }.GetNewClosure()
                switch ($boundaryValue) {
                    'partial' {
                        $validation = [ordered]@{ valid = $false; request = [ordered]@{ allowPartial = $false }; doctor = [ordered]@{}; errors = @([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = '합성 부분 분석 확인' }) }
                        return (Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -InputReader $reader -ValidationInvoker $mutationInvoker 6>$null).interaction
                    }
                    'round' { return Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $runValue -InputReader $reader -RoundInvoker $mutationInvoker 6>$null }
                    'apply' { return Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary common -Run $runValue -IssueId 'D-001' -Text 'B' -InputReader $reader -ConstraintInvoker $mutationInvoker 6>$null }
                    'defer' { return Read-DuoForgeExactConfirmationInternal -Token 'DEFER' -Prompt '확인' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -InputReader $reader 6>$null }
                }
            } $fixture.run $boundary $control $lineInput.reader $tempRoot
            $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
            $expectedTarget = if ($boundary -eq 'defer') { 'shell' } elseif ($case.action -eq 'back') { 'parent' } elseif ($boundary -eq 'partial') { 'home' } else { 'work-menu' }
            Assert-Equal $interaction.action $case.action "$boundary/$($case.name)의 줄 입력 action이 다릅니다."
            Assert-Equal $interaction.returnTarget $expectedTarget "$boundary/$($case.name)의 줄 입력 복귀 위치가 다릅니다."
            Assert-Equal $control.calls 0 "$boundary/$($case.name)에서 mutation invoker가 호출되었습니다."
            Assert-Equal $lineInput.state.remaining 0
            Assert-Equal $after $before "$boundary/$($case.name)의 줄 입력에서 영구 상태가 변경되었습니다."
        }
    }
}

Test-Case 'ROUND/APPLY/DEFER 리디렉션은 입력과 mutation 없이 unavailable로 즉시 돌아간다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'exact-boundary-unavailable'
    foreach ($boundary in @('round', 'apply', 'defer')) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ calls = 0 }
        $interaction = & $module {
            param($runValue, $boundaryValue, $state, $workspace)
            $mutationInvoker = { $state.calls++; throw '리디렉션 경로에서 mutation을 호출하면 안 됩니다.' }.GetNewClosure()
            $redirected = { [ordered]@{ cursor = $false; reason = 'redirected' } }
            switch ($boundaryValue) {
                'round' { return Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $runValue -RoundInvoker $mutationInvoker -ConfirmationCapabilityProbe $redirected 6>$null }
                'apply' { return Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary common -Run $runValue -IssueId 'D-001' -Text 'Q' -ConstraintInvoker $mutationInvoker -ConfirmationCapabilityProbe $redirected 6>$null }
                'defer' { return Read-DuoForgeExactConfirmationInternal -Token 'DEFER' -Prompt '확인' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -CapabilityProbe $redirected 6>$null }
            }
        } $fixture.run $boundary $control $tempRoot
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $interaction.action 'unavailable' "$boundary 리디렉션이 unavailable이 아닙니다."
        Assert-Equal $interaction.returnTarget $(if ($boundary -eq 'defer') { 'shell' } else { 'work-menu' }) "$boundary 리디렉션 복귀 위치가 다릅니다."
        Assert-Equal $control.calls 0 "$boundary 리디렉션에서 mutation invoker가 호출되었습니다."
        Assert-Equal $after $before "$boundary 리디렉션에서 영구 상태가 변경되었습니다."
    }
}

Test-Case 'PARTIAL/ROUND/APPLY/DEFER 오타는 같은 확인 화면에 정확 토큰 경고를 남긴다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'exact-boundary-invalid-frame'
    $typoKeys = @(Get-DuoForgeInteractionAbortCases | Where-Object { $_.name -eq '오타' } | Select-Object -ExpandProperty keys)
    foreach ($boundary in @('partial', 'round', 'apply', 'defer')) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ calls = 0; frames = [System.Collections.Generic.List[string]]::new() }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys $typoKeys
        $interaction = & $module {
            param($runValue, $boundaryValue, $state, $reader, $workspace)
            $mutationInvoker = { $state.calls++; throw '오타 경로에서 mutation을 호출하면 안 됩니다.' }.GetNewClosure()
            $frameWriter = { param($lines) $state.frames.Add(($lines -join "`n")) }.GetNewClosure()
            switch ($boundaryValue) {
                'partial' {
                    $validation = [ordered]@{ valid = $false; request = [ordered]@{ allowPartial = $false }; doctor = [ordered]@{}; errors = @([ordered]@{ code = 'DF-PARTIAL-CONSENT-REQUIRED'; message = '합성 부분 분석 확인' }) }
                    return (Confirm-DuoForgeInteractivePartialAnalysisInternal -Validation $validation -ReturnTarget parent -CancelReturnTarget home -InterruptReturnTarget home -ValidationInvoker $mutationInvoker -ConfirmationKeyReader $reader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter $frameWriter 6>$null).interaction
                }
                'round' { return Invoke-DuoForgeInteractiveRoundConfirmationInternal -Run $runValue -RoundInvoker $mutationInvoker -ConfirmationKeyReader $reader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter $frameWriter 6>$null }
                'apply' { return Invoke-DuoForgeInteractiveApplyBoundaryInternal -Boundary answer -Run $runValue -IssueId 'D-001' -Text 'B' -DecisionInvoker $mutationInvoker -ConfirmationKeyReader $reader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter $frameWriter 6>$null }
                'defer' { return Read-DuoForgeExactConfirmationInternal -Token 'DEFER' -Prompt '확인' -ReturnTarget shell -CancelReturnTarget shell -InterruptReturnTarget shell -KeyReader $reader -CapabilityProbe { $true } -FrameWriter $frameWriter 6>$null }
            }
        } $fixture.run $boundary $control $keyInput.reader $tempRoot
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $token = switch ($boundary) { 'partial' { 'PARTIAL' }; 'round' { 'ROUND' }; 'apply' { 'APPLY' }; default { 'DEFER' } }
        Assert-Equal $interaction.action 'back'
        Assert-ContainsText ($control.frames -join "`n---`n") "확인어 $token" "$boundary 오타 경고가 정확 토큰을 안내하지 않습니다."
        Assert-Equal $control.calls 0
        Assert-Equal $keyInput.state.remaining 0
        Assert-Equal $after $before "$boundary 오타 경로에서 영구 상태가 변경되었습니다."
    }
}

Test-Case '대화형 LIVE 확인의 Esc/B/Q/Ctrl+C/오타는 재개와 저장 변경을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'interactive-live-abort'
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ resume = 0 }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $interaction = & $module {
            param($runValue, $state, $keyReader)
            $resumeInvoker = {
                param($runId, $resultsRoot, $consent)
                $state.resume++
                throw '취소 경로에서 재개하면 안 됩니다.'
            }.GetNewClosure()
            Invoke-DuoForgeInteractiveLiveResume -Run $runValue -ResumeInvoker $resumeInvoker -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
        } $fixture.run $control $keyInput.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $control.resume 0 "$($case.name)에서 resume이 호출되었습니다."
        Assert-Equal $interaction.action $case.expectedAction "$($case.name)의 interaction action이 다릅니다."
        Assert-Equal $interaction.returnTarget 'work-menu' "$($case.name)의 복귀 위치가 다릅니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "$($case.name)의 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0 "$($case.name)의 합성 키가 남았습니다."
        Assert-Equal $after $before "$($case.name)에서 run·파일·답변·단계 상태가 변경되었습니다."
    }
}

Test-Case 'CLI resume --live의 Esc/B/Q/Ctrl+C/오타는 재개와 저장 변경을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'cli-live-abort'
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ resume = 0 }
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $null = & $module {
            param($runValue, $workspace, $state, $keyReader)
            $resumeInvoker = {
                param($runId, $resultsRoot, $consent)
                $state.resume++
                throw '취소 경로에서 재개하면 안 됩니다.'
            }.GetNewClosure()
            (& {
                Invoke-DuoForgeCliCoreInternal -Arguments @('resume', '--run', [string]$runValue.state.runId, '--workspace', $workspace, '--live') -ResumeInvoker $resumeInvoker -InteractiveHostProbe { $true } -ConfirmationKeyReader $keyReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) }
            } 6>&1 | Out-String) | Out-Null
        } $fixture.run $fixture.workspace $control $keyInput.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $control.resume 0 "$($case.name)에서 resume이 호출되었습니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "$($case.name)의 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0 "$($case.name)의 합성 키가 남았습니다."
        Assert-Equal $after $before "$($case.name)에서 run·파일·답변·단계 상태가 변경되었습니다."
    }
}

Test-Case '정확한 LIVE와 Enter만 주입한 대화형·CLI 재개 invoker를 각각 한 번 호출한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'live-submit'
    $control = [ordered]@{ interactive = 0; cli = 0 }
    $submitKeys = @(
        [ConsoleKeyInfo]::new('L', [ConsoleKey]::L, $true, $false, $false)
        [ConsoleKeyInfo]::new('I', [ConsoleKey]::I, $true, $false, $false)
        [ConsoleKeyInfo]::new('V', [ConsoleKey]::V, $true, $false, $false)
        [ConsoleKeyInfo]::new('E', [ConsoleKey]::E, $true, $false, $false)
        [ConsoleKeyInfo]::new([char]13, [ConsoleKey]::Enter, $false, $false, $false)
    )
    $interactiveReader = New-DuoForgeInteractionTestKeyReader -Keys $submitKeys
    $cliReader = New-DuoForgeInteractionTestKeyReader -Keys $submitKeys
    $null = & $module {
        param($runValue, $workspace, $state, $firstReader, $secondReader)
        $interactiveInvoker = { param($runId, $resultsRoot, $consent) $state.interactive++; return [ordered]@{ status = 'SYNTHETIC'; invoked = 0 } }.GetNewClosure()
        $cliInvoker = { param($runId, $resultsRoot, $consent) $state.cli++; return [ordered]@{ status = 'SYNTHETIC'; invoked = 0 } }.GetNewClosure()
        (& { Invoke-DuoForgeInteractiveLiveResume -Run $runValue -ResumeInvoker $interactiveInvoker -ConfirmationKeyReader $firstReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } } 6>&1 | Out-String) | Out-Null
        (& { Invoke-DuoForgeCliCoreInternal -Arguments @('resume', '--run', [string]$runValue.state.runId, '--workspace', $workspace, '--live') -ResumeInvoker $cliInvoker -InteractiveHostProbe { $true } -ConfirmationKeyReader $secondReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } } 6>&1 | Out-String) | Out-Null
    } $fixture.run $fixture.workspace $control $interactiveReader.reader $cliReader.reader
    Assert-Equal $control.interactive 1
    Assert-Equal $control.cli 1
    Assert-Equal $interactiveReader.state.remaining 0
    Assert-Equal $cliReader.state.remaining 0
}

Test-Case 'LIVE 추가 설명 확인의 이탈 입력은 provider와 설명 기록을 만들지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'explanation-live-abort'
    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $control = [ordered]@{ provider = 0 }
        $interactiveReader = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $cliReader = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $interaction = & $module {
            param($runValue, $workspace, $state, $firstReader, $secondReader)
            $providerInvoker = { param($provider, $prompt, $issue) $state.provider++; throw '취소 경로에서 provider를 호출하면 안 됩니다.' }.GetNewClosure()
            $interactiveResult = Invoke-DuoForgeInteractiveIssueExplanation -Run $runValue -IssueId 'D-001' -Provider codex -Level general -ProviderInvoker $providerInvoker -ConfirmationKeyReader $firstReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } 6>$null
            (& { Invoke-DuoForgeCliCoreInternal -Arguments @('explain', '--run', [string]$runValue.state.runId, '--workspace', $workspace, '--issue', 'D-001', '--provider', 'codex', '--live') -ProviderInvoker $providerInvoker -InteractiveHostProbe { $true } -ConfirmationKeyReader $secondReader -ConfirmationCapabilityProbe { $true } -ConfirmationFrameWriter { param($lines) } } 6>&1 | Out-String) | Out-Null
            return $interactiveResult
        } $fixture.run $fixture.workspace $control $interactiveReader.reader $cliReader.reader
        $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        Assert-Equal $control.provider 0 "$($case.name)에서 provider가 호출되었습니다."
        Assert-Equal $interaction.action $case.expectedAction "$($case.name)의 추가 설명 action이 다릅니다."
        Assert-Equal $interaction.returnTarget $case.expectedExplanationTarget "$($case.name)의 추가 설명 복귀 위치가 다릅니다."
        Assert-Equal $interactiveReader.state.reads $case.expectedReads "$($case.name)의 대화형 키 소비 수가 다릅니다."
        Assert-Equal $cliReader.state.reads $case.expectedReads "$($case.name)의 CLI 키 소비 수가 다릅니다."
        Assert-Equal $interactiveReader.state.remaining 0
        Assert-Equal $cliReader.state.remaining 0
        Assert-Equal $after $before "$($case.name)에서 설명·답변·단계 상태가 변경되었습니다."
    }
}

Test-Case '정확 확인의 줄 입력 폴백은 재입력과 Back/Cancel/Interrupt를 구분한다' {
    $cases = @(
        [ordered]@{ name = 'back'; values = @('b'); action = 'back'; target = 'parent'; reads = 1 }
        [ordered]@{ name = 'cancel'; values = @('q'); action = 'cancel'; target = 'work-menu'; reads = 1 }
        [ordered]@{ name = 'interrupt'; values = @('ctrl+c'); action = 'interrupt'; target = 'work-menu'; reads = 1 }
        [ordered]@{ name = 'invalid-then-back'; values = @('LIFE', 'b'); action = 'back'; target = 'parent'; reads = 2 }
        [ordered]@{ name = 'submit'; values = @('LIVE'); action = 'submit'; target = 'parent'; reads = 1 }
    )
    foreach ($case in $cases) {
        $lineInput = New-DuoForgeInteractionTestLineReader -Values @($case.values)
        $result = & $module {
            param($reader)
            Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt '확인' -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -InputReader $reader 6>$null
        } $lineInput.reader
        Assert-Equal $result.action $case.action "$($case.name)의 줄 입력 action이 다릅니다."
        Assert-Equal $result.returnTarget $case.target "$($case.name)의 줄 입력 복귀 위치가 다릅니다."
        Assert-Equal $lineInput.state.reads $case.reads "$($case.name)의 줄 입력 소비 수가 다릅니다."
        Assert-Equal $lineInput.state.remaining 0
    }
}

Test-Case '정확 확인 renderer 실패는 줄 입력으로 한 번 폴백한다' {
    $lineInput = New-DuoForgeInteractionTestLineReader -Values @('LIVE')
    $result = & $module {
        param($reader)
        Read-DuoForgeExactConfirmationInternal -Token 'LIVE' -Prompt '확인' -ReturnTarget shell -InputReader $reader -KeyReader { 'L' } -FrameWriter { throw 'synthetic-render-failure' } -CapabilityProbe { $true }
    } $lineInput.reader
    Assert-Equal $result.action 'submit'
    Assert-Equal $result.source 'line'
    Assert-Equal $result.returnTarget 'shell'
    Assert-Equal $lineInput.state.reads 1
    Assert-Equal $lineInput.state.remaining 0
}

Test-Case '메뉴 interaction seam은 EscapeValue 없이 구조화 결과와 세 ReturnTarget을 전달한다' {
    $capture = [ordered]@{ calls = 0; arguments = $null }
    $invoker = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $capture.calls++
        $capture.arguments = @($initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        return [ordered]@{ action = 'cancel'; value = $null; source = 'line'; returnTarget = $cancelReturnTarget }
    }.GetNewClosure()
    $result = & $module {
        param($menuInvoker)
        Invoke-DuoForgeMenuInteractionInternal -Items @([ordered]@{ value = 'go'; label = '계속'; shortcuts = @('G'); enabled = $true }) -Title '합성 호출부' -InitialSelectedIndex 0 -ReturnTarget parent -CancelReturnTarget work-menu -InterruptReturnTarget shell -MenuInvoker $menuInvoker
    } $invoker
    Assert-Equal $capture.calls 1
    Assert-Equal ($capture.arguments -join ',') '0,parent,work-menu,shell'
    Assert-Equal $result.action 'cancel'
    Assert-Equal $result.returnTarget 'work-menu'
}

Test-Case '작업 포기와 영구 삭제 확인은 취소 시 0건, 정확한 확인어에서만 1건 실행한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'run-lifecycle-confirmation'
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $calls = [ordered]@{ abandon = 0; delete = 0 }
    $abandonInvoker = { param($runId, $root) $calls.abandon++; return [ordered]@{ runId = $runId; status = 'CANCELLED' } }.GetNewClosure()
    $deleteInvoker = { param($runId, $root) $calls.delete++; return [ordered]@{ runId = $runId; status = 'DELETED'; deleted = $true } }.GetNewClosure()

    $cancelAbandon = New-DuoForgeInteractionTestLineReader -Values @('Q')
    $cancelledAbandon = & $module {
        param($runValue, $reader, $invoker)
        Invoke-DuoForgeInteractiveAbandonInternal -Run $runValue -InputReader $reader -AbandonInvoker $invoker 6>$null
    } $fixture.run $cancelAbandon.reader $abandonInvoker
    Assert-Equal $cancelledAbandon.interaction.action 'cancel'
    Assert-Equal $calls.abandon 0

    $cancelledRun = & $module { param($runValue) ConvertTo-DuoForgeHashtable -InputObject $runValue } $fixture.run
    $cancelledRun.state.status = 'CANCELLED'
    $cancelDelete = New-DuoForgeInteractionTestLineReader -Values @('B')
    $cancelledDelete = & $module {
        param($runValue, $reader, $invoker)
        Invoke-DuoForgeInteractiveDeleteInternal -Run $runValue -InputReader $reader -DeleteInvoker $invoker 6>$null
    } $cancelledRun $cancelDelete.reader $deleteInvoker
    Assert-Equal $cancelledDelete.interaction.action 'back'
    Assert-Equal $calls.delete 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $before '취소된 포기·삭제 확인에서 파일이 변경되었습니다.'

    $confirmAbandon = New-DuoForgeInteractionTestLineReader -Values @('ABANDON')
    $confirmedAbandon = & $module {
        param($runValue, $reader, $invoker)
        Invoke-DuoForgeInteractiveAbandonInternal -Run $runValue -InputReader $reader -AbandonInvoker $invoker 6>$null
    } $fixture.run $confirmAbandon.reader $abandonInvoker
    Assert-Equal $confirmedAbandon.interaction.action 'submit'
    Assert-Equal $calls.abandon 1

    $confirmDelete = New-DuoForgeInteractionTestLineReader -Values @('DELETE')
    $confirmedDelete = & $module {
        param($runValue, $reader, $invoker)
        Invoke-DuoForgeInteractiveDeleteInternal -Run $runValue -InputReader $reader -DeleteInvoker $invoker 6>$null
    } $cancelledRun $confirmDelete.reader $deleteInvoker
    Assert-Equal $confirmedDelete.interaction.action 'submit'
    Assert-Equal $calls.delete 1
}

Test-Case '작업 복원 확인은 Esc/B/Q/Ctrl+C/오타/리디렉션에서 0건이고 RESTORE에서만 1건 실행한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'run-restore-confirmation'
    $cancelledRun = & $module { param($runValue) ConvertTo-DuoForgeHashtable -InputObject $runValue } $fixture.run
    $cancelledRun.state.status = 'CANCELLED'
    $calls = [ordered]@{ restore = 0 }
    $restoreInvoker = { param($runId, $root) $calls.restore++; return [ordered]@{ runId = $runId; status = 'PAUSED_USER'; restored = $true } }.GetNewClosure()

    foreach ($case in @(Get-DuoForgeInteractionAbortCases)) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $keyInput = New-DuoForgeInteractionTestKeyReader -Keys @($case.keys)
        $outcome = & $module {
            param($runValue, $reader, $invoker)
            Invoke-DuoForgeInteractiveRestoreInternal -Run $runValue -RestoreInvoker $invoker -ConfirmationKeyReader $reader -ConfirmationFrameWriter { param($lines) } -ConfirmationCapabilityProbe { $true } 6>$null
        } $cancelledRun $keyInput.reader $restoreInvoker
        Assert-Equal $outcome.interaction.action $case.expectedAction "복원/$($case.name)의 action이 다릅니다."
        Assert-Equal $outcome.interaction.returnTarget 'work-menu' "복원/$($case.name)의 복귀 위치가 다릅니다."
        Assert-Equal $keyInput.state.reads $case.expectedReads "복원/$($case.name)의 합성 키 소비 수가 다릅니다."
        Assert-Equal $keyInput.state.remaining 0
        Assert-Equal $calls.restore 0 "복원/$($case.name)에서 invoker가 호출되었습니다."
        Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $before "복원/$($case.name)에서 파일이 변경되었습니다."
    }

    $beforeRedirected = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $redirected = & $module {
        param($runValue, $invoker)
        Invoke-DuoForgeInteractiveRestoreInternal -Run $runValue -RestoreInvoker $invoker -ConfirmationCapabilityProbe { [ordered]@{ cursor = $false; renderMode = 'line'; reason = 'redirected' } } 6>$null
    } $cancelledRun $restoreInvoker
    Assert-Equal $redirected.interaction.action 'unavailable'
    Assert-Equal $redirected.interaction.returnTarget 'work-menu'
    Assert-Equal $calls.restore 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $beforeRedirected '리디렉션 복원 확인에서 파일이 변경되었습니다.'

    $confirmKeys = New-DuoForgeInteractionTestKeyReader -Keys @(New-DuoForgeInteractionTestTokenKeys -Token 'RESTORE')
    $confirmed = & $module {
        param($runValue, $reader, $invoker)
        Invoke-DuoForgeInteractiveRestoreInternal -Run $runValue -RestoreInvoker $invoker -ConfirmationKeyReader $reader -ConfirmationFrameWriter { param($lines) } -ConfirmationCapabilityProbe { $true } 6>$null
    } $cancelledRun $confirmKeys.reader $restoreInvoker
    Assert-Equal $confirmed.interaction.action 'submit'
    Assert-Equal $confirmed.result.status 'PAUSED_USER'
    Assert-Equal $calls.restore 1
    Assert-Equal $confirmKeys.state.remaining 0
}

Test-Case 'CLI abandon, restore, delete는 확인 이탈을 보존하고 정확한 확인에서만 실행한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'run-lifecycle-cli'
    $calls = [ordered]@{ abandon = 0; restore = 0; delete = 0; resume = 0 }
    $abandonInvoker = { param($runId, $root) $calls.abandon++; return [ordered]@{ runId = $runId; status = 'CANCELLED' } }.GetNewClosure()
    $restoreInvoker = { param($runId, $root) $calls.restore++; return [ordered]@{ runId = $runId; status = 'PAUSED_USER'; restored = $true } }.GetNewClosure()
    $deleteInvoker = { param($runId, $root) $calls.delete++; return [ordered]@{ runId = $runId; status = 'DELETED'; deleted = $true } }.GetNewClosure()
    $resumeInvoker = { param($runId, $root, $live) $calls.resume++; throw '복원에서 resume를 호출하면 안 됩니다.' }.GetNewClosure()
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot

    $cancelReader = (New-DuoForgeInteractionTestLineReader -Values @('Q')).reader
    $cancelled = @(& $module {
        param($runId, $root, $reader, $invoker)
        Invoke-DuoForgeCliCoreInternal -Arguments @('abandon', '--run', $runId, '--workspace', $root) -InputReader $reader -AbandonInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $cancelReader $abandonInvoker)
    Assert-Equal (@($cancelled | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('action') }).Count) 0
    Assert-Equal $calls.abandon 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $before

    $confirmReader = (New-DuoForgeInteractionTestLineReader -Values @('ABANDON')).reader
    $confirmed = & $module {
        param($runId, $root, $reader, $invoker)
        Invoke-DuoForgeCliCoreInternal -Arguments @('abandon', '--run', $runId, '--workspace', $root) -InputReader $reader -AbandonInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $confirmReader $abandonInvoker
    Assert-Equal $confirmed.status 'CANCELLED'
    Assert-Equal $calls.abandon 1

    Assert-ThrowsCode {
        & $module {
            param($runId, $root, $restore)
            Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root, '--confirm-restore') -RestoreInvoker $restore -InteractiveHostProbe { $false } 6>$null
        } ([string]$fixture.run.state.runId) $fixture.workspace $restoreInvoker
    } 'DF-RUN-RESTORE-STATE'
    Assert-Equal $calls.restore 0

    $null = & $module {
        param($directory)
        $statePath = Join-Path $directory 'state.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        $state.status = 'CANCELLED'
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    } $fixture.run.runDirectory

    $beforeRestore = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $restoreCancelReader = (New-DuoForgeInteractionTestLineReader -Values @('Q')).reader
    $cancelledRestore = @(& $module {
        param($runId, $root, $reader, $restore, $resume)
        Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root) -InputReader $reader -RestoreInvoker $restore -ResumeInvoker $resume -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $restoreCancelReader $restoreInvoker $resumeInvoker)
    Assert-Equal (@($cancelledRestore | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('action') }).Count) 0
    Assert-Equal $calls.restore 0
    Assert-Equal $calls.resume 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $beforeRestore

    $restoreConfirmReader = (New-DuoForgeInteractionTestLineReader -Values @('RESTORE')).reader
    $confirmedRestore = & $module {
        param($runId, $root, $reader, $restore, $resume)
        Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root) -InputReader $reader -RestoreInvoker $restore -ResumeInvoker $resume -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $restoreConfirmReader $restoreInvoker $resumeInvoker
    Assert-Equal $confirmedRestore.status 'PAUSED_USER'
    Assert-Equal $calls.restore 1
    Assert-Equal $calls.resume 0

    Assert-ThrowsCode {
        & $module {
            param($runId, $root, $restore, $resume)
            Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root) -RestoreInvoker $restore -ResumeInvoker $resume -InteractiveHostProbe { $false } 6>$null
        } ([string]$fixture.run.state.runId) $fixture.workspace $restoreInvoker $resumeInvoker
    } 'DF-RUN-RESTORE-CONFIRM'
    Assert-Equal $calls.restore 1
    Assert-Equal $calls.resume 0

    $confirmedRestoreFlag = & $module {
        param($runId, $root, $restore, $resume)
        Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root, '--confirm-restore') -RestoreInvoker $restore -ResumeInvoker $resume -InteractiveHostProbe { $false } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $restoreInvoker $resumeInvoker
    Assert-Equal $confirmedRestoreFlag.status 'PAUSED_USER'
    Assert-Equal $calls.restore 2
    Assert-Equal $calls.resume 0

    Assert-ThrowsCode {
        & $module {
            param($runId, $root, $restore)
            Invoke-DuoForgeCliCoreInternal -Arguments @('restore', '--run', $runId, '--workspace', $root, '--confirm-restore=false') -RestoreInvoker $restore -InteractiveHostProbe { $false } 6>$null
        } ([string]$fixture.run.state.runId) $fixture.workspace $restoreInvoker
    } 'DF-CLI-OPTION'
    Assert-Equal $calls.restore 2

    $beforeDelete = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $deleteCancelReader = (New-DuoForgeInteractionTestLineReader -Values @('B')).reader
    $cancelledDelete = @(& $module {
        param($runId, $root, $reader, $invoker)
        Invoke-DuoForgeCliCoreInternal -Arguments @('delete', '--run', $runId, '--workspace', $root) -InputReader $reader -DeleteInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $deleteCancelReader $deleteInvoker)
    Assert-Equal (@($cancelledDelete | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('action') }).Count) 0
    Assert-Equal $calls.delete 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $beforeDelete

    $deleteConfirmReader = (New-DuoForgeInteractionTestLineReader -Values @('DELETE')).reader
    $confirmedDelete = & $module {
        param($runId, $root, $reader, $invoker)
        Invoke-DuoForgeCliCoreInternal -Arguments @('delete', '--run', $runId, '--workspace', $root) -InputReader $reader -DeleteInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $deleteConfirmReader $deleteInvoker
    Assert-Equal $confirmedDelete.status 'DELETED'
    Assert-Equal $calls.delete 1

    Assert-ThrowsCode {
        & $module {
            param($runId, $root, $invoker)
            Invoke-DuoForgeCliCoreInternal -Arguments @('delete', '--run', $runId, '--workspace', $root) -DeleteInvoker $invoker -InteractiveHostProbe { $false } 6>$null
        } ([string]$fixture.run.state.runId) $fixture.workspace $deleteInvoker
    } 'DF-RUN-DELETE-CONFIRM'
    Assert-Equal $calls.delete 1
}

Test-Case 'CLI 도움말은 포기한 작업 복원과 실패 재시도 명령을 안내한다' {
    $help = (& $module { Write-DuoForgeHelp 6>&1 } | Out-String)
    Assert-ContainsText $help 'duoforge restore --run <실행 ID> [--workspace <폴더>] [--confirm-restore]'
    Assert-ContainsText $help 'duoforge retry-failed --run <실행 ID> [--workspace <폴더>] [--confirm-retry]'
}

Test-Case '작업 메뉴와 홈은 포기와 영구 삭제를 별도 항목으로 표시한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'run-lifecycle-menus'
    $activeCapture = [ordered]@{ items = $null }
    $activeMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $activeCapture.items = @($items)
        return [ordered]@{ action = 'back'; value = $null; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menuInvoker)
        Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menuInvoker 6>$null
    } $fixture.run $activeMenu
    Assert-Equal @($activeCapture.items | Where-Object value -eq 'abandon').Count 1
    Assert-Equal @($activeCapture.items | Where-Object value -eq 'delete').Count 0

    $null = & $module {
        param($directory)
        $statePath = Join-Path $directory 'state.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        $state.status = 'CANCELLED'
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    } $fixture.run.runDirectory
    $cancelledCapture = [ordered]@{ items = $null }
    $cancelledMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $cancelledCapture.items = @($items)
        return [ordered]@{ action = 'back'; value = $null; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menuInvoker)
        Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menuInvoker 6>$null
    } $fixture.run $cancelledMenu
    Assert-Equal @($cancelledCapture.items | Where-Object value -eq 'abandon').Count 0
    Assert-Equal @($cancelledCapture.items | Where-Object { $_.value -eq 'restore' -and 'R' -in @($_.shortcuts) }).Count 1
    Assert-Equal @($cancelledCapture.items | Where-Object value -eq 'delete').Count 1

    $restoreCalls = [ordered]@{ count = 0 }
    $restoreInvoker = { param($runId, $root) $restoreCalls.count++; return [ordered]@{ runId = $runId; status = 'PAUSED_USER'; restored = $true } }.GetNewClosure()
    $restoreMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        if ($title -ne '다음 동작') { throw "예상하지 않은 메뉴입니다: $title" }
        if (@($items | Where-Object { $_.value -eq 'restore' -and 'R' -in @($_.shortcuts) }).Count -ne 1) { throw '복원 메뉴 항목이나 R 단축키가 없습니다.' }
        return [ordered]@{ action = 'submit'; value = 'restore'; source = 'key'; returnTarget = $returnTarget }
    }
    $restoreReader = (New-DuoForgeInteractionTestLineReader -Values @('RESTORE')).reader
    $restoreResult = & $module {
        param($runValue, $menuInvoker, $reader, $invoker)
        Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menuInvoker -InputReader $reader -RestoreInvoker $invoker 6>$null
    } $fixture.run $restoreMenu $restoreReader $restoreInvoker
    Assert-Equal $restoreResult.value 'restore'
    Assert-Equal $restoreResult.returnTarget 'home'
    Assert-Equal $restoreCalls.count 1

    $homeCapture = [ordered]@{ items = $null }
    $homeMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $homeCapture.items = @($items)
        return [ordered]@{ action = 'submit'; value = 'exit'; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menuInvoker)
        Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker { @([ordered]@{ runId = [string]$runValue.state.runId; name = '포기 작업'; mode = 'shared-document'; status = 'CANCELLED'; updatedAt = ''; runDirectory = [string]$runValue.runDirectory }) } -MenuInvoker $menuInvoker 6>$null
    } $fixture.run $homeMenu
    Assert-Equal @($homeCapture.items | Where-Object { [string]$_.label -eq '포기한 작업 관리 (1)' -and [string]$_.value -eq '5' }).Count 1
    Assert-Equal @($homeCapture.items | Where-Object { [string]$_.label -eq '실행 환경 확인, 로그인 및 설정' -and [string]$_.value -eq '6' }).Count 1
}

Test-Case '실패한 작업은 홈 전용 목록과 제한된 다시 시도 준비 동작에 나타난다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'failed-run-menu'
    $null = & $module {
        param($directory)
        $statePath = Join-Path $directory 'state.json'
        $stepsPath = Join-Path $directory 'steps.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        $graph = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $stepsPath)
        $step = @($graph.steps)[0]
        $step.status = 'FAILED'
        $step.attemptCount = 2
        $step.totalAttemptCount = 2
        $step.retryMode = 'RETRY_EXHAUSTED'
        $step.lastError = [ordered]@{ code = 'DF-PROVIDER-TIMEOUT'; retryable = $true; diagnosticId = 'diag-synthetic' }
        $state.status = 'FAILED_STAGE'
        Write-DuoForgeJsonAtomic -Path $stepsPath -Value $graph
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    } $fixture.run.runDirectory

    $homeCapture = [ordered]@{ items = $null }
    $homeMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $homeCapture.items = @($items)
        return [ordered]@{ action = 'submit'; value = 'exit'; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menuInvoker)
        Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker { @([ordered]@{ runId = [string]$runValue.state.runId; name = '실패 작업'; mode = 'shared-document'; status = 'FAILED_STAGE'; updatedAt = ''; runDirectory = [string]$runValue.runDirectory }) } -MenuInvoker $menuInvoker 6>$null
    } $fixture.run $homeMenu
    Assert-Equal @($homeCapture.items | Where-Object { [string]$_.label -eq '진행 중인 작업 보기 (0)' }).Count 1
    Assert-Equal @($homeCapture.items | Where-Object { [string]$_.label -eq '실패한 작업 확인 (1)' -and [string]$_.value -eq '4' }).Count 1

    $workCapture = [ordered]@{ items = $null }
    $workMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $workCapture.items = @($items)
        return [ordered]@{ action = 'back'; value = $null; source = 'line'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menuInvoker)
        Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menuInvoker 6>$null
    } $fixture.run $workMenu
    Assert-Equal @($workCapture.items | Where-Object { $_.value -eq 'retry-failed' -and [bool]$_.enabled }).Count 1
    Assert-Equal @($workCapture.items | Where-Object value -eq 'R').Count 0
    Assert-Equal @($workCapture.items | Where-Object value -eq 'abandon').Count 1

    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $cancelCalls = [ordered]@{ count = 0 }
    $cancelReader = (New-DuoForgeInteractionTestLineReader -Values @('B')).reader
    $cancelResult = & $module {
        param($runId, $root, $reader, $control)
        $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $root
        $invoker = { param($id, $resultsRoot) $control.count++; throw '취소 경로에서 다시 시도를 준비하면 안 됩니다.' }.GetNewClosure()
        Invoke-DuoForgeInteractiveFailedRetryInternal -Run $run -InputReader $reader -RetryInvoker $invoker 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $cancelReader $cancelCalls
    Assert-Equal $cancelResult.interaction.action 'back'
    Assert-Equal $cancelResult.interaction.returnTarget 'work-menu'
    Assert-Equal $cancelCalls.count 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $before

    $retryCalls = [ordered]@{ count = 0 }
    $retryReader = (New-DuoForgeInteractionTestLineReader -Values @('RETRY')).reader
    $retryResult = & $module {
        param($runId, $root, $reader, $control)
        $run = Get-DuoForgeRunInternal -RunId $runId -ResultsRoot $root
        $invoker = { param($id, $resultsRoot) $control.count++; return [ordered]@{ runId = $id; status = 'RESUMABLE_ERROR'; providerCalls = 0 } }.GetNewClosure()
        Invoke-DuoForgeInteractiveFailedRetryInternal -Run $run -InputReader $reader -RetryInvoker $invoker 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $retryReader $retryCalls
    Assert-Equal $retryCalls.count 1
    Assert-Equal $retryResult.result.status 'RESUMABLE_ERROR'
    Assert-Equal $retryResult.result.providerCalls 0

    $cliBefore = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $cliCalls = [ordered]@{ count = 0 }
    $cliCancelReader = (New-DuoForgeInteractionTestLineReader -Values @('Q')).reader
    $null = & $module {
        param($runId, $root, $reader, $control)
        $invoker = { param($id, $resultsRoot) $control.count++; throw '취소 경로에서 CLI가 다시 시도를 준비하면 안 됩니다.' }.GetNewClosure()
        Invoke-DuoForgeCliCoreInternal -Arguments @('retry-failed', '--run', $runId, '--workspace', $root) -InputReader $reader -RetryInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $cliCancelReader $cliCalls
    Assert-Equal $cliCalls.count 0
    Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $cliBefore

    $cliRetryReader = (New-DuoForgeInteractionTestLineReader -Values @('RETRY')).reader
    $cliResult = & $module {
        param($runId, $root, $reader, $control)
        $invoker = { param($id, $resultsRoot) $control.count++; return [ordered]@{ runId = $id; status = 'RESUMABLE_ERROR'; providerCalls = 0 } }.GetNewClosure()
        Invoke-DuoForgeCliCoreInternal -Arguments @('retry-failed', '--run', $runId, '--workspace', $root) -InputReader $reader -RetryInvoker $invoker -InteractiveHostProbe { $true } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $cliRetryReader $cliCalls
    Assert-Equal $cliCalls.count 1
    Assert-Equal $cliResult.status 'RESUMABLE_ERROR'
    Assert-Equal $cliResult.providerCalls 0

    Assert-ThrowsCode {
        & $module {
            param($runId, $root, $control)
            $invoker = { param($id, $resultsRoot) $control.count++; throw '무확인 CLI에서 다시 시도를 준비하면 안 됩니다.' }.GetNewClosure()
            Invoke-DuoForgeCliCoreInternal -Arguments @('retry-failed', '--run', $runId, '--workspace', $root) -RetryInvoker $invoker -InteractiveHostProbe { $false } 6>$null
        } ([string]$fixture.run.state.runId) $fixture.workspace $cliCalls
    } 'DF-RUN-RETRY-CONFIRM'
    Assert-Equal $cliCalls.count 1

    $cliFlagResult = & $module {
        param($runId, $root, $control)
        $invoker = { param($id, $resultsRoot) $control.count++; return [ordered]@{ runId = $id; status = 'RESUMABLE_ERROR'; providerCalls = 0 } }.GetNewClosure()
        Invoke-DuoForgeCliCoreInternal -Arguments @('retry-failed', '--run', $runId, '--workspace', $root, '--confirm-retry') -RetryInvoker $invoker -InteractiveHostProbe { $false } 6>$null
    } ([string]$fixture.run.state.runId) $fixture.workspace $cliCalls
    Assert-Equal $cliCalls.count 2
    Assert-Equal $cliFlagResult.providerCalls 0
}

Test-Case '홈의 빈 진행/완료/실패/포기 분류를 실제 선택해도 안내 뒤 홈에 남고 파일을 변경하지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'empty-home-categories'
    $cases = @(
        [ordered]@{ choice = '2'; status = 'COMPLETED'; message = '진행 중인 작업이 없습니다.' }
        [ordered]@{ choice = '3'; status = 'PAUSED_USER'; message = '완료된 결과가 없습니다.' }
        [ordered]@{ choice = '4'; status = 'PAUSED_USER'; message = '실패한 작업이 없습니다.' }
        [ordered]@{ choice = '5'; status = 'PAUSED_USER'; message = '포기한 작업이 없습니다.' }
    )
    foreach ($case in $cases) {
        $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
        $state = [ordered]@{ menuCalls = 0; runReads = 0 }
        $menuInvoker = {
            param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
            if ($title -ne 'DuoForge') { throw "빈 분류에서 작업 선택 메뉴로 진입했습니다: $title" }
            $state.menuCalls++
            if ($state.menuCalls -eq 1) { return [ordered]@{ action = 'submit'; value = [string]$case.choice; source = 'key'; returnTarget = $returnTarget } }
            return [ordered]@{ action = 'submit'; value = 'exit'; source = 'key'; returnTarget = $returnTarget }
        }.GetNewClosure()
        $runsInvoker = {
            $state.runReads++
            return @([ordered]@{
                runId = [string]$fixture.run.state.runId
                name = '다른 분류 작업'
                mode = 'shared-document'
                status = [string]$case.status
                updatedAt = ''
                runDirectory = [string]$fixture.run.runDirectory
            })
        }.GetNewClosure()
        $output = (& $module {
            param($runs, $menu)
            Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker $runs -MenuInvoker $menu 6>&1
        } $runsInvoker $menuInvoker | Out-String)
        Assert-ContainsText $output ([string]$case.message) "홈 [$($case.choice)] 빈 목록 안내가 없습니다."
        Assert-Equal $state.menuCalls 2 "홈 [$($case.choice)]가 안내 뒤 홈으로 돌아오지 않았습니다."
        Assert-Equal $state.runReads 2 "홈 [$($case.choice)]가 실행 목록을 다시 읽지 않았습니다."
        Assert-Equal (Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot) $before "홈 [$($case.choice)] 빈 목록 선택에서 파일이 변경되었습니다."
    }
}

Test-Case '홈과 작업 제어기는 interaction 객체를 성공 출력으로 노출하지 않는다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'controller-success-output'
    $runRecord = [ordered]@{
        runId = [string]$fixture.run.state.runId
        name = '합성 작업'
        mode = 'shared-document'
        status = [string]$fixture.run.state.status
        updatedAt = ''
        runDirectory = [string]$fixture.run.runDirectory
    }

    $workBackState = [ordered]@{ homeCalls = 0 }
    $workBackMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget)
        if ($title -eq 'DuoForge') {
            $workBackState.homeCalls++
            $value = if ($workBackState.homeCalls -eq 1) { '2' } else { 'exit' }
            return [ordered]@{ action = 'submit'; value = $value; source = 'key'; returnTarget = $returnTarget }
        }
        if ($title -eq '작업을 선택해 주세요.') { return [ordered]@{ action = 'submit'; value = '0'; source = 'key'; returnTarget = $returnTarget } }
        if ($title -eq '다음 동작') { return [ordered]@{ action = 'back'; value = $null; source = 'key'; returnTarget = $returnTarget } }
        throw "예상하지 않은 메뉴입니다: $title"
    }.GetNewClosure()
    $workBackOutput = @(& $module {
        param($record, $menu)
        $runsInvoker = { @($record) }.GetNewClosure()
        Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker $runsInvoker -MenuInvoker $menu 6>$null
    } $runRecord $workBackMenu)

    $newBackState = [ordered]@{ homeCalls = 0 }
    $newBackMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget)
        if ($title -eq 'DuoForge') {
            $newBackState.homeCalls++
            $value = if ($newBackState.homeCalls -eq 1) { '1' } else { 'exit' }
            return [ordered]@{ action = 'submit'; value = $value; source = 'key'; returnTarget = $returnTarget }
        }
        if ($title -eq '무엇을 하시겠습니까?') { return [ordered]@{ action = 'back'; value = $null; source = 'key'; returnTarget = $returnTarget } }
        throw "예상하지 않은 메뉴입니다: $title"
    }.GetNewClosure()
    $newBackOutput = @(& $module {
        param($menu)
        Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker { @() } -MenuInvoker $menu 6>$null
    } $newBackMenu)

    $liveCancelState = [ordered]@{ homeCalls = 0; workCalls = 0 }
    $liveCancelMenu = {
        param($items, $title, $initialSelectedIndex, $returnTarget)
        if ($title -eq 'DuoForge') {
            $liveCancelState.homeCalls++
            $value = if ($liveCancelState.homeCalls -eq 1) { '2' } else { 'exit' }
            return [ordered]@{ action = 'submit'; value = $value; source = 'key'; returnTarget = $returnTarget }
        }
        if ($title -eq '작업을 선택해 주세요.') { return [ordered]@{ action = 'submit'; value = '0'; source = 'key'; returnTarget = $returnTarget } }
        if ($title -eq '다음 동작') {
            $liveCancelState.workCalls++
            if ($liveCancelState.workCalls -eq 1) { return [ordered]@{ action = 'submit'; value = 'R'; source = 'key'; returnTarget = $returnTarget } }
            return [ordered]@{ action = 'back'; value = $null; source = 'key'; returnTarget = $returnTarget }
        }
        throw "예상하지 않은 메뉴입니다: $title"
    }.GetNewClosure()
    $liveCancelOutput = @(& $module {
        param($record, $menu)
        $runsInvoker = { @($record) }.GetNewClosure()
        Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker $runsInvoker -InputReader { param($prompt) 'Q' } -MenuInvoker $menu 6>$null
    } $runRecord $liveCancelMenu)

    $homeExitOutput = @(& $module {
        $homeInvoker = {
            Invoke-DuoForgeInteractiveHome `
                -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } `
                -RunsInvoker { @() } `
                -InputReader { param($prompt) 'Q' }
        }
        Invoke-DuoForgeCliCoreInternal -Arguments $null -InteractiveHostProbe { $true } -InteractiveHomeInvoker $homeInvoker 6>$null
    })

    $deferOutput = @(& $module {
        param($workspace)
        $decisionInvoker = { throw '취소 경로에서 보류 답변을 기록하면 안 됩니다.' }
        Invoke-DuoForgeCliCoreInternal -Arguments @('defer', '--run', 'synthetic-run', '--issue', 'D-001', '--workspace', $workspace) -InputReader { param($prompt) 'Q' } -DecisionInvoker $decisionInvoker -InteractiveHostProbe { $true } 6>$null
    } $tempRoot)

    foreach ($case in @(
        [ordered]@{ name = '홈 -> 작업 -> 뒤로 -> 홈 종료'; output = $workBackOutput }
        [ordered]@{ name = '홈 -> 새 작업 -> 뒤로 -> 홈 종료'; output = $newBackOutput }
        [ordered]@{ name = '홈 -> 작업 -> LIVE 취소 -> 뒤로 -> 홈 종료'; output = $liveCancelOutput }
        [ordered]@{ name = '무인자 CLI -> 홈 Q 종료'; output = $homeExitOutput }
        [ordered]@{ name = '명시적 CLI DEFER 취소'; output = $deferOutput }
    )) {
        $interactions = @($case.output | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.Contains('action') })
        Assert-Equal $interactions.Count 0 "$($case.name) 성공 출력에 interaction 객체가 노출되었습니다."
    }
}

Test-Case '실제 작업 상세 ContextTransition 메뉴는 높이 24행 이상에서 푸터 앞 빈 행을 둔다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'work-menu-transition-spacing'
    $capture = [ordered]@{ items = @(); title = '' }
    $menuInvoker = {
        param($items, $title, $initialSelectedIndex, $returnTarget)
        $capture.items = @($items)
        $capture.title = [string]$title
        return [ordered]@{ action = 'back'; value = $null; source = 'key'; returnTarget = $returnTarget }
    }.GetNewClosure()
    $null = & $module {
        param($runValue, $menu)
        Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menu 6>$null
    } $fixture.run $menuInvoker

    Assert-Equal $capture.title '다음 동작'
    $frames = & $module {
        param($items, $title)
        $result = [ordered]@{}
        $normalizedItems = @(ConvertTo-DuoForgeMenuItemsInternal -Items $items)
        foreach ($size in @(@(72, 20), @(80, 24), @(100, 30), @(120, 32))) {
            $width = [int]$size[0]
            $height = [int]$size[1]
            $result["${width}x${height}"] = @(New-DuoForgeMenuFrameInternal -Items $normalizedItems -Title $title -Width $width -Height $height -ContextTransition)
        }
        return $result
    } $capture.items $capture.title
    foreach ($size in @(@(72, 20), @(80, 24), @(100, 30), @(120, 32))) {
        $width = [int]$size[0]
        $height = [int]$size[1]
        $lines = @($frames["${width}x${height}"])
        if ($height -le 23) {
            Assert-False ([string]::IsNullOrWhiteSpace([string]$lines[-2])) "${width}x${height} compact 작업 메뉴의 푸터 앞 압축이 유지되지 않았습니다."
        }
        else {
            Assert-Equal ([string]$lines[-2]) '' "${width}x${height} 작업 메뉴의 마지막 항목과 푸터 사이 빈 행이 없습니다."
        }
    }
}

Test-Case '레거시 메뉴 호출부는 실패 action별 화면 복귀 위치를 구조화 seam에 고정한다' {
    $fixture = New-DuoForgeInteractionTestRun -Name 'legacy-menu-targets'
    $selectionOptions = [ordered]@{
        displayName = '합성 AI'
        catalogSource = 'synthetic'
        suggestedModels = @([ordered]@{ value = 'known-model'; displayName = 'known-model'; recommended = $true; description = '합성'; reasoningEfforts = @('high'); recommendedReasoningEffort = 'high' })
        reasoningEfforts = @('high')
        recommendedReasoningEffort = 'high'
    }
    $blockedReport = New-FakeDoctor
    $blockedReport.readyForDocumentModes = $false
    $capture = [System.Collections.Generic.List[object]]::new()
    $backInvoker = {
        param($items, $title, $initialSelectedIndex, $returnTarget, $cancelReturnTarget, $interruptReturnTarget)
        $capture.Add([ordered]@{ title = [string]$title; back = $returnTarget; cancel = $cancelReturnTarget; interrupt = $interruptReturnTarget })
        return [ordered]@{ action = 'back'; value = $null; source = 'line'; returnTarget = 'shell' }
    }.GetNewClosure()
    $null = & $module {
        param($runDirectory)
        $statePath = Join-Path $runDirectory 'state.json'
        $state = ConvertTo-DuoForgeHashtable -InputObject (Read-DuoForgeJson -Path $statePath)
        $state.decisionReviewCycle = 1
        Write-DuoForgeJsonAtomic -Path $statePath -Value $state
    } $fixture.run.runDirectory
    $before = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot
    $null = & $module {
        param($options, $report, $runValue, $workspace, $menuInvoker)
        $null = Read-DuoForgeModelChoiceInternal -Provider codex -SelectionOptions $options -MenuInvoker $menuInvoker 6>$null
        $null = Read-DuoForgeReasoningEffortChoiceInternal -Provider codex -Model 'known-model' -SelectionOptions $options -MenuInvoker $menuInvoker 6>$null
        $null = Read-DuoForgePathChoice -Prompt '새 작업 경로' -Role test -MenuInvoker $menuInvoker 6>$null
        $null = Read-DuoForgePathChoice -Prompt '추가 자료 경로' -Role test -CancelReturnTarget work-menu -InterruptReturnTarget work-menu -MenuInvoker $menuInvoker 6>$null
        $doctorInvoker = { $report }.GetNewClosure()
        $null = Invoke-DuoForgeInteractiveSetup -DoctorInvoker $doctorInvoker -MenuInvoker $menuInvoker 6>$null
        $null = Invoke-DuoForgeInteractiveNew -MenuInvoker $menuInvoker 6>$null
        $null = Select-DuoForgeInteractiveRun -Runs @([ordered]@{ name = '합성'; mode = 'shared-document'; status = 'PAUSED_USER' }) -Prompt '작업 선택' -MenuInvoker $menuInvoker 6>$null
        $null = Invoke-DuoForgeInteractiveRun -RunRecord ([ordered]@{ runId = [string]$runValue.state.runId; runDirectory = [string]$runValue.runDirectory }) -MenuInvoker $menuInvoker 6>$null
        $null = Invoke-DuoForgeInteractiveHome -SetupInvoker { [ordered]@{ readyForDocumentModes = $true } } -RunsInvoker { @() } -MenuInvoker $menuInvoker 6>$null
    } $selectionOptions $blockedReport $fixture.run $fixture.workspace $backInvoker
    $after = Get-DuoForgeInteractionTestTreeSnapshot -Root $tempRoot

    $targets = @($capture | ForEach-Object { '{0}:{1}/{2}/{3}' -f $_.title, $_.back, $_.cancel, $_.interrupt })
    Assert-True (@($targets | Where-Object { $_ -like '합성 AI 모델을 선택해 주세요.:parent/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -like '합성 AI 분석 깊이를 선택해 주세요.*:parent/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '새 작업 경로:parent/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '추가 자료 경로:parent/work-menu/work-menu' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '실행 환경 복구:home/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '무엇을 하시겠습니까?:home/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '작업 선택:home/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq '다음 동작:home/home/home' }).Count -eq 1)
    Assert-True (@($targets | Where-Object { $_ -eq 'DuoForge:shell/shell/shell' }).Count -eq 1)
    Assert-Equal $after $before '메뉴 실패 경계에서 run·파일·답변·단계 상태가 변경되었습니다.'
}

Test-Case '표시된 이전 행의 Enter와 B 단축키는 같은 back 결과를 반환한다' {
    $items = @(
        [ordered]@{ value = 'next'; label = '계속'; shortcuts = @('N'); enabled = $true }
        [ordered]@{ value = 'back'; label = '이전으로'; shortcuts = @('B'); enabled = $true }
    )
    $enter = & $module { param($menuItems) Read-DuoForgeMenuInteractionInternal -Items $menuItems -Title '이전 행' -InitialSelectedIndex 1 -ReturnTarget work-menu -CancelReturnTarget home -InterruptReturnTarget shell -KeyReader { 'Enter' } -FrameWriter { param($lines) } -CapabilityProbe { $true } } $items
    $shortcut = & $module { param($menuItems) Read-DuoForgeMenuInteractionInternal -Items $menuItems -Title '이전 단축키' -ReturnTarget work-menu -CancelReturnTarget home -InterruptReturnTarget shell -KeyReader { 'B' } -FrameWriter { param($lines) } -CapabilityProbe { $true } } $items
    Assert-Equal $enter.action 'back'
    Assert-Equal $enter.returnTarget 'work-menu'
    Assert-Equal $shortcut.action 'back'
    Assert-Equal $shortcut.returnTarget 'work-menu'
}

Test-Case '레거시 EscapeValue와 화면별 magic string 메뉴 어댑터는 제품 코드에 남지 않는다' {
    $menuSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\DuoForge\Private\13.MenuView.ps1') -Raw
    $interactionSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\DuoForge\Private\13.Interaction.ps1') -Raw
    $interactiveControllerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\DuoForge\Private\14.Interactive.ps1') -Raw
    $cliControllerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'src\DuoForge\Public\Cli.ps1') -Raw
    $productSources = @(
        'src\DuoForge\Private\08.ModelSelection.ps1'
        'src\DuoForge\Private\11.RecentPaths.ps1'
        'src\DuoForge\Private\13.MenuView.ps1'
        'src\DuoForge\Private\14.Interactive.ps1'
    ) | ForEach-Object { Get-Content -LiteralPath (Join-Path $projectRoot $_) -Raw }
    Assert-NotContainsText $menuSource 'EscapeValue'
    Assert-NotContainsText $menuSource 'Invoke-DuoForgeLineMenuSelectionInternal'
    Assert-NotContainsText $menuSource 'Invoke-DuoForgeMenuSelectionInternal'
    Assert-NotContainsText ($productSources -join "`n") 'Invoke-DuoForgeMenuInternal'
    Assert-NotContainsText $interactionSource 'back-to-question'
    Assert-NotContainsText $interactionSource "& `$MenuInvoker `$Items `$Title 'back'"
    Assert-ContainsText $interactiveControllerSource '$null = Invoke-DuoForgeInteractiveLiveResume -Run $run'
    Assert-ContainsText $interactiveControllerSource '$null = Invoke-DuoForgeInteractiveNew -InputReader $InputReader'
    Assert-ContainsText $interactiveControllerSource '$null = Invoke-DuoForgeInteractiveRun -RunRecord $selected'
    Assert-NotContainsText $cliControllerSource 'return $confirmation'
    Assert-NotContainsText $cliControllerSource 'return $partialConfirmation.interaction'
    Assert-NotContainsText $cliControllerSource 'return $creation.interaction'
}

Test-Case '직접 Read-Host와 원시 ReadKey는 공통 interaction 저수준 경계에만 남는다' {
    $sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src\DuoForge') -Filter '*.ps1' -File -Recurse)
    $readHostHits = @($sourceFiles | Select-String -Pattern '\bRead-Host\b')
    $readKeyHits = @($sourceFiles | Select-String -Pattern '\[Console\]::ReadKey\(')
    Assert-Equal $readHostHits.Count 1
    Assert-Equal $readKeyHits.Count 1
    Assert-Equal $readHostHits[0].Path (Join-Path $projectRoot 'src\DuoForge\Private\13.Interaction.ps1')
    Assert-Equal $readKeyHits[0].Path (Join-Path $projectRoot 'src\DuoForge\Private\13.Interaction.ps1')
    Assert-ContainsText $readHostHits[0].Line 'Read-Host $Prompt'
    Assert-ContainsText $readKeyHits[0].Line 'ReadKey($true)'
}
