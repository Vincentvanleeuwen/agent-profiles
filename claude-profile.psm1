# Compatibility module. New integrations import agent-profile.psm1.
Import-Module (Join-Path $PSScriptRoot 'agent-profile.psm1') -Force -Global
