# ShopNexus

ShopNexus is a C2C marketplace for used goods in Vietnam. Buyers inspect an item at delivery and pay the carrier in cash. Sellers ship through their own carrier account. The platform holds no money and does not adjudicate disputes.

## Components

| Component | Purpose |
|---|---|
| Server | Marketplace API, data, search, and durable order flows |
| Android app | Buyer and seller marketplace experience |
| Website | Public storefront and marketplace experience |
| Console and agent | Moderation tools and assisted operations |
| Docs | Product and developer documentation, requirements, and reports |
| Brand | Shared visual identity and assets |

Each component is maintained in its own repository and included here as a submodule.

## Local development

Clone with submodules and start Docker Compose:

```bash
git clone --recurse-submodules https://github.com/shopnexus/shopnexus.git
cd shopnexus
make dev
```

The storefront is available at `http://shopnexus.localhost:56481`. `make test` runs the server tests, and `make down` stops the local stacks while keeping their data.

## Deployment

GitHub Actions builds each component's container image. The Kubernetes cluster runs separate development and production stacks, managed by Argo CD. Compose provides local development and a production-image profile for checking the same components on one machine.

## License

GNU AGPL-3.0. Code committed before 2026-11-23 remains under MIT.
