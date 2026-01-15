@echo off
:: Executa o script PowerShell de limpeza do WSUS como administrador e mantém a janela aberta

:: Cria um arquivo VBS temporário que solicita elevação
echo Set UAC = CreateObject^("Shell.Application"^) > "%TEMP%\ElevateWSUS.vbs"
echo UAC.ShellExecute "powershell.exe", "-NoExit -ExecutionPolicy Bypass -Command ""& {& 'C:\Users\manut\Downloads\WSUS - Manutenção\Clean_Wsus.ps1'; Write-Host 'Script concluido. A janela permanecera aberta para visualizacao dos resultados.' -ForegroundColor Green}""", "", "runas", 1 >> "%TEMP%\ElevateWSUS.vbs"

:: Executa o VBS para iniciar o PowerShell como administrador
"%TEMP%\ElevateWSUS.vbs"

:: Remove o arquivo temporário
del "%TEMP%\ElevateWSUS.vbs"