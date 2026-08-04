FROM alpine:3.20

RUN apk add --no-cache tinyproxy

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter.allow /etc/tinyproxy/filter.allow

EXPOSE 8888
CMD ["tinyproxy", "-d"]
