# PSScriptAnalyzerSettings.psd1 - used by tests/Lint.Tests.ps1 and CI.
# The gate: no Error findings anywhere, no Warning findings in src/ and the wrapper. Excluded rules:
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # module-private helpers named after the jq builtin they mirror (Get-JqUnique, Sort-JqBy, Get-ExcCounts ...)
        'PSUseSingularNouns'
        # read-only tool: the "state-changing" verbs here (New-*, Set-BcrOpt ...) only build in-memory objects
        'PSUseShouldProcessForStateChangingFunctions'
        # false positives: parameters used inside nested script blocks (sort keys, parallel region scan)
        'PSReviewUnusedParameter'
        # source files are UTF-8 without BOM (PowerShell 7 default); Windows PowerShell 5.1 is not supported
        'PSUseBOMForUnicodeEncodedFile'
        # the log goes to stderr and the report to stdout on purpose (pipeable output; same as the Bash tool)
        'PSAvoidUsingWriteHost'
        # module-private helpers keep the jq name they mirror (Round-Jq = jq round, Sort-JqBy = jq sort_by)
        'PSUseApprovedVerbs'
    )
}
