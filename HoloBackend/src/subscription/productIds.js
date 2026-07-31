export const HOLO_PLUS_PRODUCT_IDS = Object.freeze({
  monthly: "com.tangyuxuan.holo.plus.monthly",
  yearly: "com.tangyuxuan.holo.plus.yearly",
});

export function tierForProductId(productId) {
  return Object.values(HOLO_PLUS_PRODUCT_IDS).includes(productId) ? "plus" : "free";
}
