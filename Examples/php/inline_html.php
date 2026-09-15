<?php $title = "Report"; $rows = [['a', 1], ['b', 2]]; ?>
<h1><?= $title ?></h1>
<table>
<?php foreach ($rows as $row): ?>
  <tr><td><?= $row[0] ?></td><td><?= $row[1] * 10 ?></td></tr>
<?php endforeach; ?>
</table>
<?php if (count($rows) > 1): ?>
<p>rows: <?= count($rows) ?></p>
<?php else: ?>
<p>empty</p>
<?php endif; ?>
