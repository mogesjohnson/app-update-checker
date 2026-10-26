@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The coloured table is the script's user interface; Write-Host is intentional.
        'PSAvoidUsingWriteHost',
        # Script parameters are read by the functions through scope, which the rule cannot see.
        'PSReviewUnusedParameter',
        # Tests set variables that the code under test reads through scope.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
