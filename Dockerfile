ARG BASE_IMAGE=debian:12
FROM --platform=linux/amd64 ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    SPARK_HOME=/opt/spark \
    SPARK_DAEMON_CLASSPATH="/opt/extra-jars/*" \
    SPARK_NO_DAEMONIZE=true
ENV PATH="${SPARK_HOME}/bin:${SPARK_HOME}/sbin:${JAVA_HOME}/bin:${PATH}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends openjdk-17-jre-headless procps tini \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /opt/extra-jars /opt/event-logs

# Spark distribution installed by setup.sh. The jars (/opt/extra-jars) are mounted at run time.
COPY dist/spark ${SPARK_HOME}
RUN test -f ${SPARK_HOME}/sbin/start-history-server.sh \
 || { echo "error: dist/spark is not a Spark distribution; run ./setup.sh" >&2; exit 1; }

WORKDIR ${SPARK_HOME}
EXPOSE 18080

# SPARK_NO_DAEMONIZE=true keeps start-history-server.sh in the foreground so the container stays up.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./sbin/start-history-server.sh"]
