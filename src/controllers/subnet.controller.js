const { calculateSubnet } = require('../services/subnet.service');

// Errors thrown here go to the error handler in app.js.
exports.calculate = (req, res) => {
  res.json(calculateSubnet(req.body?.cidr));
};
