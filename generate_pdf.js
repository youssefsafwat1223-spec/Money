const puppeteer = require('puppeteer');

(async () => {
  const browser = await puppeteer.launch();
  const page = await browser.newPage();
  await page.goto('file:///Users/youssef/Documents/Money/script.html', { waitUntil: 'networkidle0' });
  await page.pdf({ 
      path: '/Users/youssef/Documents/Money/وراء_الكواليس.pdf', 
      format: 'A4', 
      printBackground: true,
      margin: {
          top: '20px',
          bottom: '20px',
          left: '20px',
          right: '20px'
      }
  });
  await browser.close();
})();
