ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache restic rclone openssh-client curl jq

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD ["/run.sh"]
