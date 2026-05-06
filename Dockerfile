FROM debian:13

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      createrepo-c rpm debsigs gnupg dpkg-dev gzip apt-utils \
      osslsigncode default-jre-headless curl \
      ruby ruby-dev gcc make jq && \
    gem install --no-document fpm && \
    curl -sL https://github.com/ebourg/jsign/releases/download/7.4/jsign-7.4.jar \
      -o /usr/local/lib/jsign.jar && \
    printf '#!/bin/sh\nexec java -jar /usr/local/lib/jsign.jar "$@"\n' \
      > /usr/local/bin/jsign && \
    chmod +x /usr/local/bin/jsign && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
