# WSUS - Limpeza e Manutencao

Script PowerShell para limpeza e manutencao do WSUS com verificacoes de saude,
reindexacao seletiva de tabelas e um menu interativo para escolher as operacoes.

## Conteudo do repo

- `Clean_Wsus.ps1`: script principal com verificacoes de seguranca, limpeza e reindexacao.
- `Executar.bat`: atalho para executar o script como administrador (com elevacao UAC).

## Requisitos

- Windows Server com a role do WSUS instalada.
- PowerShell com permissao de administrador.
- Modulo `UpdateServices` instalado (`Install-WindowsFeature UpdateServices`).
- `sqlcmd` disponivel no servidor (usado para checar fragmentacao do WID).

## Como usar

1. Abra o PowerShell como Administrador.
2. Execute o script:

```powershell
.\Clean_Wsus.ps1
```

O script abre um menu interativo com as opcoes:

- 1: Recusar apenas atualizacoes substituidas.
- 2: Limpar apenas arquivos desnecessarios.
- 3: Reindexar banco de dados (recomendado quando houver fragmentacao).
- 4: Executar todas as operacoes em sequencia.
- 5: Sair.

## Usando o Executar.bat

O `Executar.bat` chama o PowerShell com elevacao. Ele contem um caminho fixo
para o script (`C:\Users\manut\Downloads\WSUS - Manutencao\Clean_Wsus.ps1`).
Se voce for usar esse atalho, ajuste o caminho para o local correto do script.

## Observacoes

- O script verifica se esta rodando como Administrador e se o modulo
  `UpdateServices` esta disponivel.
- A verificacao/reindexacao esta implementada para WID; SQL Server dedicado
  nao esta implementado no script atual.
