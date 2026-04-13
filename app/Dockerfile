FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o app main.go

FROM alpine:3.20

WORKDIR /app
COPY --from=builder /src/app /app/app

EXPOSE 8080

ENV ADDR=:8080
ENV DATA_FILE_PATH=/data/data.jsonl

CMD ["/app/app"]
