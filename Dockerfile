FROM debian:latest

# Build with:
# docker build --tag jstrieb/paperify:latest .

RUN apt-get update && \
  apt-get install --no-install-recommends --yes \
    pandoc \
    curl ca-certificates \
    jq \
    python3 \
    imagemagick \
    texlive texlive-publishers texlive-science lmodern texlive-latex-extra

COPY paperify.sh /usr/local/bin/paperify
RUN chmod +x /usr/local/bin/paperify

WORKDIR /root/
ENTRYPOINT ["paperify"]
