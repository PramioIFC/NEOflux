$ErrorActionPreference = 'Stop'

if (-not (Test-Path '.env')) {
    Copy-Item '.env.example' '.env'
    Write-Host 'Criado: .env'
}

if (-not (Test-Path 'config.json')) {
    Copy-Item 'config.example.json' 'config.json'
    Write-Host 'Criado: config.json'
}

Write-Host 'Preencha .env e config.json. Depois siga o README.'

