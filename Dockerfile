FROM google/cloud-sdk:464.0.0

COPY run-builder.sh /bin/
CMD ["bash", "-xe", "/bin/run-builder.sh"]
