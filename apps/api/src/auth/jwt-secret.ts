export function getJwtSecret() {
  const secret = process.env.JWT_SECRET?.trim();
  if (!secret || secret === 'change-me-in-production' || secret.length < 32) {
    throw new Error('JWT_SECRET must be configured with a strong production value.');
  }
  return secret;
}
