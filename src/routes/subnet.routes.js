const router = require('express').Router();
const { calculate } = require('../controllers/subnet.controller');

router.post('/', calculate);

module.exports = router;
