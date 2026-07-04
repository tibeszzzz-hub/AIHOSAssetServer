FROM swift:6.0-jammy AS build

WORKDIR /app
COPY . .

RUN swift build -c release

EXPOSE 8080

CMD ["swift", "run", "-c", "release"]
