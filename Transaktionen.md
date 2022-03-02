# Transaktionen

## Generieren einer ID für neue Bestellungen

Das Problem ist, dass die ID der letzten Bestellung aus der Datenbank gelesen wird und dann sich in der Java Applikationen befindet. Dann wird diese ID von Java an die Datenbank zurückgesendet und damit eine neue Order mit einer um 1 erhöten ID erstellt. Während sich die ID in der Java Applikation befindet gibt es allerdings keine Garantie, dass sich die höchste ID in der Zwischenzeit nicht verändert (z.B.: dadurch, dass eine weitere Anfrage die früher passiert ist jetzt eine neue Bestellung erstellt). Wenn dann die Bestellung hinzugefügt wird kann es zu einem Konflikt zwischen den Bestellungsnummern kommen und die neue Bestellung nicht hinzugefügt werden.

```shell
curl --parallel --parallel-immediate "http://localhost:8000/placeOrder?client_id=1&article_id_1=1&amount_1=1&article_id_2=2&amount_2=1" "http://localhost:8000/placeOrder?client_id=1&article_id_1=1&amount_1=1&article_id_2=2&amount_2=1"
```

Mit dem curl Befehl können zwei Bestellungen gleichzeitig durchgeführt werden. Dadurch zeigt sich der Fehler, der entsteht wenn die Race-Condition passiert:

```org.postgresql.util.PSQLException: ERROR: duplicate key value violates unique constraint "orders_pkey"
org.postgresql.util.PSQLException: ERROR: duplicate key value violates unique constraint "orders_pkey"
  Detail: Key (id)=(19) already exists.
```

Wie vorhergesagt gibt es während der zweiten Bestellung bereits die zuvor festgestellte Bestellungsnummer wordurch die unique contraint nicht erfüllt wird.

Eine naive Möglichkeit wäre einfach eine Transaktion zu starten und zu hoffen, dadurch das Problem gelöst wird. Auch hier ergibt sich allerdings der gleiche Fehler:

```
org.postgresql.util.PSQLException: ERROR: duplicate key value violates unique constraint "orders_pkey"
  Detail: Key (id)=(21) already exists.
```

Dann kann man versuchen durch ein gezielt gesetztes Transaction Isolation Level den Fehler zu beheben. Hier bietet sich nur das Isolation Level `TRANSACTION_SERIALIZABLE`, da es verspricht Phantom Reads zu verhindern, daher dass sich ein `SELECT` mit einer bestimmten Bedingung (in unserem Fall die maximale ID + 1) wiederholt mit dem gleichen Ergebnis durchführen lässt. Dabei entsteht allerdings der Fehler:

```
org.postgresql.util.PSQLException: ERROR: could not serialize access due to read/write dependencies among transactions
  Detail: Reason code: Canceled on identification as a pivot, during write.
  Hint: The transaction might succeed if retried.
```

Dies passiert, da Postgresql im Transaction Isolation Level `TRANSACTION_SERIALIZABLE` nur während der Transaction garantiert, dass alle `SELECT` Statements von dem Zustand am Beginn der aktuellen Transaktion lesen, allerdings nicht, dass beim Ausführen der Transaction Bedingungen wie Unique Constriants für den neuen (möglicherweise veränderten) Zustand der Datenbank noch garantiert werden und daher verschieben wir durch das Setzen eine Isolation Levels nur die Stelle wo der Fehler auftritt vom `INSERT INTO` zum commiten. Die tatsächliche Lösung wäre es einen `SHARE ROW EXCLUSIVE` LOCK auf die Table zu bekommen, um zu garantieren, dass auch andere gleichzeitige Statements nicht die Daten der Datenbank verändert werden können. Andere anfragen müssen dann darauf warten, dass sie auch die Tabelle locken können. Dadürch werden die beiden Anfragen dann nacheinander durchgeführt.

```
{"order_id": 23}{"order_id": 24}
```

```
Webshop running at http://127.0.0.1:8000
Placing order using thread pool-1-thread-2 / 18
Placing order using thread pool-1-thread-1 / 17
Finished placing order using thread pool-1-thread-2 / 18
Finished placing order using thread pool-1-thread-1 / 17
```

## Atomizität bei Bestellungen

Wenn mehrere Bestellung zeitgleich die Menge eines Produkts abrufen und dann veringern kann es zu einem Problem kommen bei dem die Menge des Produkts unter 0 sinkt. Dies können wir umgehen indem wir für die Dauer der Transaktion die Zeile des Produkts in der Produkte Tabelle für Veränderungen locken. Dies gilt dann innerhalb der for-Schleife. Hier verwenden wir während der Transaktion in der for-Schleife den Lock Modus `ROW EXCLUSIVE`, welcher es uns ermöglicht an SELECT Statements `FOR UPDATE` anzuhängen um zu signalisieren, dass wir die ausgewählten Reihen locken. Dann commiten wir nach jedem Durchlauf der for-Schleife die Transaktion für ein neues Produkt, damit wir nicht  andere Anfragen unnötig aufhalten.

Um die Erstellung von leeren Bestellungen zu verhindern ohne die Performence zu mindern (daher einfach für die Dauer der gesamten Anfrage Locks für alle involvierten Tabellen innerhalb einer Transaktion zu halten), können wir einfach die Anzahl der tatsächlich erstellten Produkte mitzählen und falls keine Produkte hinzugefügt wurden die Bestellung wieder löschen.