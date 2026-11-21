# ---- build ----
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download || true
COPY . .
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /panda-app ./

# ---- runtime ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /panda-app /panda-app
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/panda-app"]
