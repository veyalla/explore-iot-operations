FROM --platform=linux/amd64 ubuntu

# Install required packages
RUN apt-get update && apt-get install -y mosquitto-clients wget && rm -rf /var/lib/apt/lists/*

# Install Step CLI and cURL
RUN apt-get update && \
    wget https://dl.smallstep.com/gh-release/cli/docs-cli-install/v0.23.4/step-cli_0.23.4_amd64.deb && \
    apt-get install -y ./step-cli_0.23.4_amd64.deb curl && \
    rm ./step-cli_0.23.4_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# Install Dapr CLI
RUN wget -q https://raw.githubusercontent.com/dapr/cli/master/install/install.sh -O - | /bin/bash

# Install mqttui
RUN apt-get update && \
    wget https://github.com/EdJoPaTo/mqttui/releases/download/v0.21.1/mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb && \
    apt-get install -y ./mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb && \
    rm -rf ./mqttui-v0.21.1-x86_64-unknown-linux-gnu.deb && \
    rm -rf /var/lib/apt/lists/*

# Install k9s
RUN wget https://github.com/derailed/k9s/releases/download/v0.28.0/k9s_Linux_amd64.tar.gz && \
    tar xf k9s_Linux_amd64.tar.gz --directory=/usr/local/bin k9s && \
    chmod +x /usr/local/bin/k9s && \
    rm -rf k9s_Linux_amd64.tar.gz

# Install Starship prompt
RUN curl -sS https://starship.rs/install.sh | sh -s -- --version v1.21.1 --yes

