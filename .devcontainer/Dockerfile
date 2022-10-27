FROM rust:1-bullseye as base

# Setup env
ENV PATH=/usr/local/cargo/bin:/home/admin/.local/bin:$PATH

# Install OS packages
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get -y install openssh-client sudo git curl build-essential wget \
    && apt-get clean

RUN curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash - \
    && sudo apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest \
    && npm install --global yarn \
    && node --version \
    && npm --version \
    && yarn --version 

RUN wget https://github.com/aptos-labs/aptos-core/releases/download/aptos-cli-v1.0.0/aptos-cli-1.0.0-Ubuntu-x86_64.zip \
    && apt-get update \
    && apt-get install unzip \
    && unzip aptos-cli-1.0.0-Ubuntu-x86_64.zip \
    && sudo mv aptos /bin \
    && rm aptos-cli-1.0.0-Ubuntu-x86_64.zip

RUN cargo install --git https://github.com/move-language/move move-cli --branch main \
    && cargo install --git https://github.com/move-language/move move-analyzer
    
# Fix login shell
RUN useradd -G sudo -U -m -s /bin/bash admin \
    && echo "admin ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER admin
