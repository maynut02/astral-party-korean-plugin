# Compatibility entry point for the previous WindowsPlugin build command.
param(
    [string]$Version = '',
    [string]$WorkRoot = '',
    [string]$OutputRoot = '',
    [string]$DotNetPath = ''
)
& (Join-Path $PSScriptRoot 'package-release.ps1') @PSBoundParameters
