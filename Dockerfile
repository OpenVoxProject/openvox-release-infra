FROM debian:13

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      createrepo-c rpm debsigs gnupg dpkg-dev gzip apt-utils \
      osslsigncode default-jre-headless curl \
      ruby ruby-dev gcc make jq && \
    gem install --no-document fpm && \
    curl -sL https://github.com/ebourg/jsign/releases/download/7.5/jsign-7.5.jar \
      -o /usr/local/lib/jsign.jar && \
    echo '602a51c3545a6dc4fb99bd2ea7152b26d1345916d0c93ddfbd5936cb735af91c  /usr/local/lib/jsign.jar' \
      | sha256sum -c - && \
    printf '#!/bin/sh\nexec java -jar /usr/local/lib/jsign.jar "$@"\n' \
      > /usr/local/bin/jsign && \
    chmod +x /usr/local/bin/jsign && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
