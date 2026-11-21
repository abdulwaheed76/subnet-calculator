const app = require('./app');

const port = process.env.PORT || 3000;
const server = app.listen(port, () => console.log(`Listening on port ${port}`));

// `docker stop` sends SIGTERM; finish open requests instead of waiting 10s to be killed.
process.on('SIGTERM', () => server.close(() => process.exit(0)));
