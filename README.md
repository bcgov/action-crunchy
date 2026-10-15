# Crunchy (Moved)

> [!IMPORTANT]
> **This action has moved to [`bcgov/actions-openshift/crunchy`](https://github.com/bcgov/actions-openshift/tree/main/crunchy).** This repository is retiring and will be archived. Update workflows to the new path, pinned to a [release](https://github.com/bcgov/actions-openshift/releases) (not `@main`):
>
> ```yaml
> - uses: bcgov/actions-openshift/crunchy@vX.Y.Z
>   with:
>     oc_namespace: ${{ secrets.OC_NAMESPACE }}
>     oc_token: ${{ secrets.OC_TOKEN }}
>     environment: pr
> ```
>
> Inputs keep their names; the new action only adds optional ones.
