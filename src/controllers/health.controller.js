const os = require('os');

// APP_VERSION (commit SHA) and SERVER_NAME are set by the pipeline at deploy time.
exports.health = (req, res) => {
  res.json({
    status: 'ok',
    version: process.env.APP_VERSION || 'dev',
    server: process.env.SERVER_NAME || os.hostname(),
  });
};
