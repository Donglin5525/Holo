export function createEntitlementResolver({ entitlementStore, acceptanceStore }) {
  return {
    resolve(deviceId) {
      const acceptance = acceptanceStore.get(deviceId);
      if (acceptance) {
        return {
          tier: acceptance.tier,
          isPlusActive: acceptance.tier === "plus",
          productId: null,
          expiresAt: null,
          source: "acceptance",
          acceptanceMode: acceptance.tier,
          usageSubjectId: `acceptance:${deviceId}:${acceptance.tier}`,
        };
      }

      const verified = entitlementStore.get(deviceId);
      return {
        ...verified,
        source: "backend",
        acceptanceMode: "followPurchase",
        usageSubjectId: `purchase:${deviceId}`,
      };
    },
  };
}
