import { GatewayError } from "../errors.js";

export async function requireInternalDiagnostics(context, sessionService) {
  if (!sessionService) {
    throw new GatewayError("AUTH_UNAVAILABLE", "Internal diagnostics authentication is unavailable", 503);
  }

  const authorization = context.req.header("authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    throw new GatewayError("INTERNAL_DIAGNOSTICS_FORBIDDEN", "Holo session is required", 403);
  }

  try {
    const session = await sessionService.verify(match[1]);
    if (session.internalDiagnostics !== true) {
      throw new GatewayError("INTERNAL_DIAGNOSTICS_FORBIDDEN", "Internal diagnostics permission is required", 403);
    }
    return session;
  } catch (error) {
    if (error instanceof GatewayError) throw error;
    throw new GatewayError("INTERNAL_DIAGNOSTICS_FORBIDDEN", "Holo session is invalid", 403);
  }
}
