const path = require('path');
const express = require('express');
const healthRoutes = require('./routes/health.routes');
const subnetRoutes = require('./routes/subnet.routes');

const app = express();
app.disable('x-powered-by'); // don't advertise the framework to scanners

app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use('/health', healthRoutes);
app.use('/api/subnet', subnetRoutes);

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// Express only treats a handler as an error handler when it has all four arguments.
app.use((err, req, res, next) => {
  const status = err.status || 500;
  if (status >= 500) console.error(err);
  // Never send internal error details to the client.
  res.status(status).json({ error: status < 500 ? err.message : 'Internal server error' });
});

module.exports = app;
