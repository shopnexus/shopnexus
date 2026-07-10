# ShopNexus

Umbrella repository for ShopNexus. Each component lives in its own git submodule.

## Components

| Path        | Repository                                | Description        |
| ----------- | ----------------------------------------- | ------------------ |
| `app`       | `shopnexus/app`                           | Mobile app (Flutter) |
| `docs`      | `shopnexus/shopnexus-docs`                | Documentation      |
| `embedding` | `shopnexus/embedding`                     | Embedding service (Python) |
| `server`    | `shopnexus/server`                        | Backend (Go)       |
| `website`   | `shopnexus/website`                       | Web frontend (Next.js) |

## Clone

```bash
git clone --recurse-submodules git@github.com:shopnexus/shopnexus.git
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Update submodules to latest

```bash
git submodule update --remote --merge
```

## Development

```bash
docker compose up -d
```
