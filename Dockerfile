FROM swift:latest

WORKDIR /app
COPY . .

RUN swift build -c release

EXPOSE 8080

CMD [".build/release/AIHOSAssetServer"]
