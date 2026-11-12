// Dev-server proxy (local and end-to-end runs): the UI calls /api on its own origin, so the API needs no CORS setting.
// NEXUS_API_URL points at the API; the default is the port DEVELOPER_SETUP starts it on.
module.exports = {
  '/api': { target: process.env.NEXUS_API_URL || 'http://localhost:8080', secure: false, changeOrigin: false },
};
