FROM golang:1.23-alpine AS builder

WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=off go build -o app .

FROM alpine:3.20

WORKDIR /app
COPY --from=builder /src/app /app/app

EXPOSE 8080

ENV ADDR=:8080
ENV DATA_FILE_PATH=/data/data.jsonl

CMD ["/app/app"]
