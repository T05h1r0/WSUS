#Requires -RunAsAdministrator
# Requer o módulo UpdateServices (WSUS) para funcionar
# Para instalar pelo PowerShell: Install-WindowsFeature UpdateServices
Import-Module UpdateServices

<#
.SYNOPSIS
    Script completo de limpeza e manutenção do WSUS com verificações de segurança.

.DESCRIPTION
    Este script realiza operações de limpeza no WSUS com:
    - Verificação e reindexação seletiva de tabelas fragmentadas
    - Recusa de atualizações substituídas
    - Limpeza de arquivos desnecessários
    - Compactação de banco de dados
    - Verificações de segurança e saúde do servidor
    - Controle de tentativas em caso de timeout
    - Pausas estratégicas para evitar sobrecarga
    - Menu interativo para escolha de operações
#>

#region VERIFICAÇÕES INICIAIS

# Verifica se está executando como Administrador
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Execute o script como Administrador!" -ForegroundColor Red
    exit
}

# Valida o módulo UpdateServices
if (-not (Get-Module -ListAvailable -Name UpdateServices)) {
    Write-Host "O módulo 'UpdateServices' não está instalado. Execute: Install-WindowsFeature UpdateServices" -ForegroundColor Red
    exit
}

#endregion

#region FUNÇÕES AUXILIARES

# Função para padronizar as mensagens coloridas no console
function Write-ColorMessage {
    param(
        [string]$Message,
        [System.ConsoleColor]$Color,
        [bool]$NewLine = $true
    )
    
    if ($NewLine) {
        Write-Host $Message -ForegroundColor $Color
    } else {
        Write-Host $Message -ForegroundColor $Color -NoNewline
    }
}

#endregion

#region FUNÇÕES PRINCIPAIS

# Função para verificar a fragmentação do banco de dados WSUS
function Test-WsusDatabaseFragmentation {
    param (
        [string]$databaseType = "WID"
    )

    Write-ColorMessage "Verificando níveis de fragmentação do banco de dados WSUS..." Cyan
    $needsReindex = $false # Inicializa como falso por segurança
    
    try {
        if ($databaseType -eq "WID") {
            # SQL Query ajustada para ignorar tabelas pequenas (< 500 páginas)
            $sqlCommand = @"
USE SUSDB;
SELECT 
    OBJECT_NAME(ind.OBJECT_ID) AS TableName, 
    ind.name AS IndexName,
    ind.index_id AS IndexID,
    indexstats.avg_fragmentation_in_percent AS FragmentationPercentage
FROM 
    sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, NULL) indexstats
INNER JOIN 
    sys.indexes ind ON ind.object_id = indexstats.object_id AND ind.index_id = indexstats.index_id
WHERE 
    indexstats.avg_fragmentation_in_percent > 10
    AND indexstats.page_count > 500
    AND OBJECT_NAME(ind.OBJECT_ID) IN ('PUBLICATION', 'SYNCSUBSCRIPTION', 'TBSUPERSEDEDBY', 'tbUpdate', 
    'tbComputerTarget', 'tbComputerTargetDetail', 'tbComuputerStatus', 'tbTargetGroup', 
    'tbUpdateApproval', 'tbUpdateRevision')
ORDER BY 
    indexstats.avg_fragmentation_in_percent DESC;
"@

            $tempFile = "$env:Temp\WsusFragCheck.sql"
            $outputFile = "$env:Temp\WsusFragResults.txt"
            $sqlCommand | Set-Content -Path $tempFile

            # Executa a verificação de fragmentação
            Write-ColorMessage "Analisando fragmentação das tabelas principais..." Yellow
            sqlcmd -S np:\\.\pipe\MICROSOFT##WID\tsql\query -i $tempFile -o $outputFile

            # Lê os resultados
            $fragResults = Get-Content $outputFile
            $fragmentedTables = @()
            
            # Processa as linhas primeiro (silenciosamente)
            foreach ($line in $fragResults) {
                if([string]::IsNullOrWhiteSpace($line) -or $line.Trim().StartsWith('-') -or $line.Trim().ToLower().StartsWith('tablename')) {
                    continue
                }

                if ($line -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s+(\d+\.\d+)\s*$') {
                    $tableName = $matches[1]
                    $indexName = $matches[2]
                    $indexId = $matches[3]
                    $fragPercent = [double]$matches[4]

                    if (-not [string]::IsNullOrWhiteSpace($tableName) -and -not [string]::IsNullOrWhiteSpace($indexName)) {
                        $fragmentedTables += [PSCustomObject]@{
                            TableName = $tableName
                            IndexName = $indexName
                            IndexID = $indexId
                            Fragmentation = $fragPercent
                        }
                    }
                }
            }

            # AGORA decide o que mostrar com base no que encontrou
            if ($fragmentedTables.Count -eq 0) {
                Write-ColorMessage "Não foi detectada fragmentação significativa (>10% e >500 páginas)." Green
                $needsReindex = $false
            } else {
                Write-ColorMessage "Foi detectada fragmentação nas seguintes tabelas:" Yellow
                $totalFragmentation = 0
                
                foreach ($table in $fragmentedTables) {
                    $color = "Yellow"
                    if ($table.Fragmentation -gt 30) { $color = "Red" }
                    Write-ColorMessage "  Tabela: $($table.TableName), Índice: $($table.IndexName), Fragmentação: $($table.Fragmentation)%" $color
                    $totalFragmentation += $table.Fragmentation
                }

                $avgFragmentation = [math]::Round($totalFragmentation / $fragmentedTables.Count, 2)
                Write-ColorMessage "Fragmentação média: $avgFragmentation%" $(if($avgFragmentation -gt 30){"Red"}else{"Yellow"})
                
                if ($avgFragmentation -gt 20) {
                    Write-ColorMessage "Recomendação: Realizar reindexação das tabelas fragmentadas." Red
                    $needsReindex = $true
                } else {
                    Write-ColorMessage "Recomendação: Fragmentação presente, mas baixa." Yellow
                    $needsReindex = $false
                }
            }
            
            # Limpa arquivos temporários
            Remove-Item $tempFile -ErrorAction SilentlyContinue
            Remove-Item $outputFile -ErrorAction SilentlyContinue
            
            return @($needsReindex, $fragmentedTables)
            
        } elseif ($databaseType -eq "SQL") {
            Write-ColorMessage "Verificação de fragmentação para SQL Server não implementada neste script." Red
            return @($false, @())
        } else {
            Write-ColorMessage "Tipo de banco de dados desconhecido: $databaseType" Red
            return @($false, @())
        }
    } catch {
        Write-ColorMessage "Erro durante a verificação de fragmentação: $($_.Exception.Message)" Red
        return @($false, @())
    }
}

# Função para reindexar o banco de dados WSUS
# FIX PSUseApprovedVerbs: renomeado de Reindex-WsusDatabase para Invoke-WsusReindex
function Invoke-WsusReindex {
    param (
        [string]$databaseType = "WID",
        [array]$fragmentedTables = @(),
        [bool]$forceReindex = $false
    )

    Write-ColorMessage "Iniciando análise para reindexação..." Cyan

    try {
        # Verifica fragmentação se ainda não foi verificada e não estiver forçando reindexação
        if ($fragmentedTables.Count -eq 0 -and -not $forceReindex) {
            $result = Test-WsusDatabaseFragmentation $databaseType
            $needsReindex = $result[0]
            $fragmentedTables = $result[1]
            
            if (-not $needsReindex) {
                Write-ColorMessage "Reindexação não é necessária no momento." Green
                return
            }
        }

        Write-ColorMessage "Iniciando reindexação do banco de dados WSUS..." Cyan

        if ($databaseType -eq "WID") {
            $sqlCommands = @()
            $sqlCommands += "USE SUSDB;"
            $sqlCommands += "GO"
            
            # Se não há tabelas específicas listadas ou é forçado, faz tudo
            if ($fragmentedTables.Count -eq 0 -or $forceReindex) {
                Write-ColorMessage "Realizando reindexação completa de todas as tabelas principais..." Yellow
                $tabelasPadrao = @('PUBLICATION', 'SYNCSUBSCRIPTION', 'TBSUPERSEDEDBY', 'tbUpdate', 
                                   'tbComputerTarget', 'tbComputerTargetDetail', 'tbComputerStatus', 
                                   'tbTargetGroup', 'tbUpdateApproval', 'tbUpdateRevision')
                
                foreach ($tb in $tabelasPadrao) {
                     $sqlCommands += "ALTER INDEX ALL ON [$tb] REBUILD;"
                }
            } else {
                # Reindexação seletiva
                Write-ColorMessage "Realizando reindexação seletiva apenas das tabelas fragmentadas..." Yellow
                
                # Usamos um HashSet para garantir que não tentamos reindexar a mesma tabela 2x se ela tiver 2 índices ruins
                $tabelasUnicas = New-Object System.Collections.Generic.HashSet[string]
                
                foreach ($table in $fragmentedTables) {
                    if (-not [string]::IsNullOrWhiteSpace($table.TableName)) {
                        # FIX PSUseDeclaredVarsMoreThanAssignments: usar [void] em vez de $void
                        [void]$tabelasUnicas.Add($table.TableName)
                    }
                }

                foreach ($nomeTabela in $tabelasUnicas) {
                    # Em vez de tentar usar o nome do índice (que causou o erro), usamos ALL
                    # Isso repara o índice problemático E qualquer outro na mesma tabela
                    Write-ColorMessage "  -> Agendando reparo da tabela: $nomeTabela" Yellow
                    $sqlCommands += "ALTER INDEX ALL ON [$nomeTabela] REBUILD;"
                }
            }
            
            $sqlCommands += "GO"
            $sqlCommand = $sqlCommands -join "`n"

            $tempFile = "$env:Temp\WsusReindex.sql"
            $sqlCommand | Set-Content -Path $tempFile

            # Executa o comando da reindexação 
            Write-ColorMessage "Executando comandos no SQL (Isso pode demorar)..." Yellow
            sqlcmd -S np:\\.\pipe\MICROSOFT##WID\tsql\query -i $tempFile

            Remove-Item $tempFile -ErrorAction SilentlyContinue
            
            Write-ColorMessage "Reindexação concluída." Green
        }
     } catch {
        Write-ColorMessage "Erro durante a reindexação: $($_.Exception.Message)" Red
     } 
}

# Função para verificar a saúde do servidor WSUS
function Test-WsusHealth {
    param($wsus)
    
    Write-ColorMessage "Verificando saúde do servidor WSUS..." Cyan
    $healthChecks = @{
        "Conexão com Banco de Dados" = $false
        "Serviço WSUS" = $false
        "IIS" = $false
    }

    try {
        # Verifica serviço WSUS
        $wsusService = Get-Service -Name WsusService
        $healthChecks["Serviço WSUS"] = ($wsusService.Status -eq "Running")
        
        # Verifica espaço em disco (mínimo 10GB livre)
        $drive = Get-PSDrive -Name "D"
        $freeSpaceGB = [math]::Round($drive.Free/1GB, 2)
        Write-ColorMessage "  Unidade D: $freeSpaceGB GB livres" $(if($freeSpaceGB -gt 10){"Green"}else{"Yellow"})

        # Define status com base no espaço livre
        # Alerta se menos de 10GB, mas não bloqueia a execução
        $healthChecks["Espaço em Disco (D:)"] = $true
        if($freeSpaceGB -lt 10) {
            Write-ColorMessage "  ATENÇÃO: Espaço em disco baixo na unidade D:" Yellow
            Write-ColorMessage "  Recomenda-se liberar espaço após a limpeza" Yellow
        }
        
        # Verifica IIS
        $iisService = Get-Service -Name W3SVC
        $healthChecks["IIS"] = ($iisService.Status -eq "Running")
        
        # Verifica conexão com banco
        # FIX PSUseDeclaredVarsMoreThanAssignments: usar [void] em vez de $void
        [void]$wsus.GetDatabaseConfiguration()
        $healthChecks["Conexão com Banco de Dados"] = $true
        
        # Mostra resultados
        foreach ($check in $healthChecks.GetEnumerator()) {
            $status = if ($check.Value) { "OK" } else { "FALHA" }
            $color = if ($check.Value) { "Green" } else { "Red" }
            Write-ColorMessage "  $($check.Name): $status" $color
        }
        
        # Verifica fragmentação do banco de dados como parte da saúde
        Write-ColorMessage "  Verificando fragmentação do banco de dados..." Cyan
        $fragResult = Test-WsusDatabaseFragmentation "WID"
        $needsReindex = $fragResult[0]
        $fragmentedTables = $fragResult[1]
        
        if ($needsReindex) {
            $healthChecks["Banco de Dados Fragmentado"] = $false
            Write-ColorMessage "  Fragmentação do Banco de Dados: Requer Manutenção" Yellow
        } else {
            $healthChecks["Banco de Dados Fragmentado"] = $true
            Write-ColorMessage "  Fragmentação do Banco de Dados: OK" Green
        }
        
        # Retorna true para continuar a execução
        return @($true, $needsReindex, $fragmentedTables)
    }
    catch {
        Write-ColorMessage "Erro na verificação de saúde: $($_.Exception.Message)" Red
        return @($false, $false, @())
    }
}

# Função para executar operações com retry
function Invoke-WsusCleanupWithRetry {
    param (
        [string]$operationName,
        [scriptblock]$operation,
        [int]$maxRetries = 3,
        [int]$waitTimeSeconds = 120
    )
    
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-ColorMessage "Tentativa $i de $maxRetries - $operationName" Yellow
        try {
            & $operation
            Write-ColorMessage "Operação concluída com sucesso - $operationName" Green
            return $true
        }
        catch {
            Write-ColorMessage "Erro na tentativa $i - $($_.Exception.Message)" Red
            if ($i -lt $maxRetries) {
                Write-ColorMessage "Aguardando $($waitTimeSeconds/60) minutos antes de tentar novamente..." Yellow
                Start-Sleep -Seconds $waitTimeSeconds
            }
        }
    }
    return $false
}

# Função principal para recusar atualizações substituídas
function Remove-SupersededUpdates {
    param($wsus)
    
    $processed = 0
    $declined = 0
    
    Write-ColorMessage "Buscando atualizações... (isso pode demorar alguns minutos)" Yellow
    
    Get-WsusUpdate -UpdateServer $wsus -Approval Approved | ForEach-Object {
        $processed++
        
        if($_.UpdatesSupersedingThisUpdate.Count -gt 0) {
            Write-ColorMessage "Recusando: $($_.Update.Title)" Yellow
            try {
                Deny-WsusUpdate -Update $_ -Confirm:$false
                $declined++
                
                if($declined % 10 -eq 0) {
                    Start-Sleep -Seconds 2
                }
            } catch {
                Write-ColorMessage "Erro ao recusar $($_.Update.Title): $($_.Exception.Message)" Red
            }
        }
        
        if($processed % 100 -eq 0) {
            Write-ColorMessage "Processadas $processed atualizações, Recusadas $declined..." Green
            Start-Sleep -Seconds 5
        }
    }
    
    return @($processed, $declined)
}

# Função para exibir o menu e obter escolha
function Show-Menu {
    param (
        [bool]$reindexRecommended = $false
    )
    
    Write-ColorMessage "`nEscolha a operação desejada:" Cyan
    Write-ColorMessage "1 - Recusar apenas atualizações substituídas" Yellow
    Write-ColorMessage "2 - Limpar apenas arquivos desnecessários" Yellow
    if ($reindexRecommended) {
        Write-ColorMessage "3 - Reindexar banco de dados (RECOMENDADO - Fragmentação detectada)" Red
    } else {
        Write-ColorMessage "3 - Reindexar banco de dados" Yellow
    }
    Write-ColorMessage "4 - Executar todas as operações (recomendado periodicamente)" Yellow
    Write-ColorMessage "5 - Sair" Yellow

    $choice = Read-Host "Digite o número da operação"
    return $choice
}

#endregion

#region SCRIPT PRINCIPAL

try {
    Write-ColorMessage "=== Script de Limpeza WSUS ===" Cyan
    Write-ColorMessage "Conectando ao servidor WSUS..." Yellow
    $wsus = Get-WsusServer
    
    # Verifica saúde do servidor antes de prosseguir
    $healthResult = Test-WsusHealth $wsus
    $isHealthy = $healthResult[0]
    $needsReindex = $healthResult[1]
    $fragmentedTables = $healthResult[2]
    
    if (-not $isHealthy) {
        Write-ColorMessage "Problemas detectados no servidor WSUS. Resolver antes de prosseguir." Red
        return
    }

    # Loop principal do menu
    do {
        $choice = Show-Menu -reindexRecommended $needsReindex
        
        switch($choice) {
            "1" {
                Write-ColorMessage "`nIniciando recusa de atualizações substituídas..." Cyan
                $results = Remove-SupersededUpdates $wsus
                Write-ColorMessage "`n=== Resumo da Operação ===" Cyan
                Write-ColorMessage "Total de atualizações processadas: $($results[0])" Green
                Write-ColorMessage "Total de atualizações recusadas: $($results[1])" Yellow
            }
            "2" {
                Write-ColorMessage "`nIniciando limpeza de arquivos..." Cyan
                
                Invoke-WsusCleanupWithRetry "Limpando arquivos não necessários" {
                    Write-ColorMessage "Iniciando limpeza - pode demorar varios minutos..." Yellow
                    Invoke-WsusServerCleanup -UpdateServer $wsus `
                        -CleanupUnneededContentFiles `
                        -CompressUpdates `
                        -DeclineExpiredUpdates `
                        -DeclineSupersededUpdates `
                        -CleanupObsoleteUpdates
                    Start-Sleep -Seconds 30
                }
            }
            "3" {
                Write-ColorMessage "Reindexando banco de dados WSUS..." Cyan
                $fragResult = Test-WsusDatabaseFragmentation "WID"
                $fragmentedTables = $fragResult[1]
                Invoke-WsusReindex -databaseType "WID" -fragmentedTables $fragmentedTables
                # Após reindexação, atualiza o estado de necessidade
                $needsReindex = $false
            }
            "4" {
                # Executa todas as operações em sequência
                Write-ColorMessage "`nParte 1 - Recusa de atualizações substituídas..." Cyan
                $results = Remove-SupersededUpdates $wsus
                
                Write-ColorMessage "`nAguardando 2 minutos antes da próxima operação..." Yellow
                Start-Sleep -Seconds 120
                
                Write-ColorMessage "`nParte 2 - Limpeza de arquivos..." Cyan
                Invoke-WsusCleanupWithRetry "Limpando arquivos não necessários" {
                    Invoke-WsusServerCleanup -UpdateServer $wsus `
                        -CleanupUnneededContentFiles `
                        -CompressUpdates `
                        -DeclineExpiredUpdates `
                        -DeclineSupersededUpdates `
                        -CleanupObsoleteUpdates
                    Start-Sleep -Seconds 30
                }
                
                Write-ColorMessage "`nParte 3 - Verificando e reindexando banco de dados..." Cyan
                if ($needsReindex) {
                    Invoke-WsusReindex -databaseType "WID" -fragmentedTables $fragmentedTables
                    $needsReindex = $false
                } else {
                    # Verifica novamente - a limpeza pode ter alterado o estado de fragmentação
                    $fragResult = Test-WsusDatabaseFragmentation "WID"
                    $currentNeedsReindex = $fragResult[0]
                    $currentFragmentedTables = $fragResult[1]
                    
                    if ($currentNeedsReindex) {
                        Invoke-WsusReindex -databaseType "WID" -fragmentedTables $currentFragmentedTables
                    } else {
                        Write-ColorMessage "Reindexação não necessária no momento." Green
                    }
                }

                Write-ColorMessage "`n=== Resumo da Operação ===" Cyan
                Write-ColorMessage "Total de atualizações processadas: $($results[0])" Green
                Write-ColorMessage "Total de atualizações recusadas: $($results[1])" Yellow
            }
            "5" {
                Write-ColorMessage "Encerrando script..." Yellow
                break
            }
            default {
                Write-ColorMessage "Opção inválida!" Red
            }
        }

        if ($choice -ne "5") {
            Write-ColorMessage "`nDeseja realizar outra operação? (S/N)" Cyan
            $continue = Read-Host
            if ($continue.ToUpper() -ne "S") {
                Write-ColorMessage "Encerrando script..." Yellow
                break
            }
        }

    } while ($choice -ne "5")
    
} catch {
    Write-ColorMessage "Erro geral: $($_.Exception.Message)" Red
}

Write-ColorMessage "`nScript concluído!" Yellow

#endregion
