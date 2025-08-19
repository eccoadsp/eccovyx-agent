O arquivo build_cliente.ps1 deve ser usado para gerar o pacote de instalação do agente do Eccovyx.

✅ Como usar:

    .\build_cliente.ps1 -CLIENTE_ID "omega" -PROJECT_ID "ecco-agent-omega" -AGENT_TYPE "linux"

Ou para Windows:


    .\build_cliente.ps1 -CLIENTE_ID "omega" -PROJECT_ID "ecco-agent-omega" -AGENT_TYPE "windows"

✅ Pré-requisitos:
Crie um arquivo chamado agent-creds-template.json com o conteúdo base da conta de serviço, assim:


{
  "type": "service_account",
  "project_id": "PROJECT_ID_AQUI",
  ...
}
O script substitui automaticamente "project_id" no JSON para cada cliente antes de gerar o .zip.

🚀 Resultado:
Você terá um pacote como:

eccovyx-agent_linux_omega.zip

Dentro dele estará:

    eccovyx-agent (binário)

    node_exporter

    agent-creds.json (já com o project_id correto)

    install.sh (com tudo pronto para ser executado no Linux)