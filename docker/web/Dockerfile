FROM denoland/deno:debian AS builder

WORKDIR /app

COPY deno.json deno.lock ./
COPY typescript/mdr-web/package.json typescript/mdr-web/deno.json ./typescript/mdr-web/
RUN deno install --allow-scripts --frozen

COPY typescript/ ./typescript/
RUN deno task --cwd=typescript/mdr-web build

FROM denoland/deno:debian
WORKDIR /app

COPY --from=builder /app/deno.json /app/deno.lock ./
COPY --from=builder /app/node_modules/ ./node_modules/
COPY --from=builder /app/typescript/mdr-web/ ./typescript/mdr-web/

EXPOSE 3000
WORKDIR /app/typescript/mdr-web

CMD ["deno", "task", "start"]
