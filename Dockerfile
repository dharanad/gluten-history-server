# Runtime for the Spark History Server with the Gluten Velox bundle: Debian 12 (x86_64) + Java 17.
# Debian 12 matches the bundle's build target: its native libs need GLIBC >= 2.36.
#
# Nothing Spark-specific is baked in. Everything is bind-mounted at runtime (see docker-compose.yml),
# so swapping them only needs `docker compose restart`, never a rebuild:
#   /opt/spark         Spark distribution (e.g. spark-3.5.2-bin-hadoop3-scala2.13, extracted)
#   /opt/spark/conf    spark-defaults.conf etc.
#   /opt/extra-jars    Gluten bundle jar(s), added to the History Server classpath
#   /opt/event-logs    Spark event logs
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
 && mkdir -p /opt/spark /opt/extra-jars /opt/event-logs

WORKDIR ${SPARK_HOME}
EXPOSE 18080

# SPARK_NO_DAEMONIZE=true keeps start-history-server.sh in the foreground so the container stays up.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["./sbin/start-history-server.sh"]
