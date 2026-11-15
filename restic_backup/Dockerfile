FROM alpine:3.22

RUN apk add --no-cache bash restic curl jq

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
