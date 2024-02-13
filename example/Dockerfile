FROM golang:1.22.0 as builder
WORKDIR /app
COPY main.go /app/
RUN go build -o /app/os-arch /app/main.go

FROM golang:1.22.0
WORKDIR /app
COPY --from=builder /app/os-arch /app/
CMD ["bash", "-c", "/app/os-arch"]
